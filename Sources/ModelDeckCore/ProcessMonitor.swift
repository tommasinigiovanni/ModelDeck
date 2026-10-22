import Foundation
import Darwin
import IOKit

public enum ProcessSort: String, CaseIterable, Sendable {
    case cpu = "CPU", memory = "Memoria", gpu = "GPU"
}

public struct ProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    public let startedSeconds: UInt64
    public let startedMicroseconds: UInt64
    public init(pid: Int32, startedSeconds: UInt64, startedMicroseconds: UInt64) {
        self.pid = pid; self.startedSeconds = startedSeconds; self.startedMicroseconds = startedMicroseconds
    }
}

public struct RunningProcess: Identifiable, Sendable {
    public let id: ProcessIdentity
    public let name: String
    public let path: String?
    public let userID: UInt32
    public var cpu: Double?
    public let memory: UInt64?
    public var gpu: Double?
    public let gpuClient: Bool
    public let threads: Int?
    public var pid: Int32 { id.pid }
    public var isMine: Bool { userID == geteuid() }
    public var canTerminate: Bool {
        isMine && pid > 1 && pid != getpid() && !["loginwindow", "WindowServer", "launchd", "kernel_task"].contains(name)
    }
    public init(id: ProcessIdentity, name: String, path: String?, userID: UInt32, cpu: Double?, memory: UInt64?, gpu: Double?, gpuClient: Bool, threads: Int?) {
        self.id = id; self.name = name; self.path = path; self.userID = userID; self.cpu = cpu
        self.memory = memory; self.gpu = gpu; self.gpuClient = gpuClient; self.threads = threads
    }
}

public actor ProcessMonitor {
    private struct Counters { let cpu: UInt64?; let gpu: UInt64?; let sampledAt: TimeInterval }
    private var previous: [ProcessIdentity: Counters] = [:]
    public init() {}

    public func sample() -> [RunningProcess] {
        let capacity = max(512, Int(proc_listallpids(nil, 0)) + 256)
        var pids = [Int32](repeating: 0, count: capacity)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard count > 0 else { return [] }
        let now = ProcessInfo.processInfo.systemUptime
        let gpuClients = Self.gpuClients()
        var results: [RunningProcess] = [], next: [ProcessIdentity: Counters] = [:]
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard var bsd = Self.bsd(pid) else { continue }
            let identity = Self.identity(pid, bsd)
            var task = proc_taskinfo()
            let taskValid = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) == MemoryLayout<proc_taskinfo>.size
            let cpuTime: UInt64? = taskValid ? task.pti_total_user &+ task.pti_total_system : nil
            let gpuTime = gpuClients.contains(pid) || pid == getpid() ? Self.gpuTime(pid) : nil
            let old = previous[identity]
            let cpu = Self.percent(current: cpuTime, previous: old?.cpu, elapsed: old.map { now - $0.sampledAt })
            // Some Apple GPU drivers return a constant zero despite successful task_info.
            // Zero is not proof that the driver supports attribution: require observed GPU time.
            let supportsGPU = (gpuTime ?? 0) > 0 || (old?.gpu ?? 0) > 0
            let gpu = supportsGPU ? Self.percent(current: gpuTime, previous: old?.gpu, elapsed: old.map { now - $0.sampledAt }) : nil
            next[identity] = Counters(cpu: cpuTime, gpu: gpuTime, sampledAt: now)
            var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let path = pathLength > 0 ? String(cString: pathBuffer) : nil
            let short = withUnsafePointer(to: &bsd.pbi_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
            }
            let name = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? (short.isEmpty ? "Processo \(pid)" : short)
            results.append(RunningProcess(id: identity, name: name, path: path, userID: bsd.pbi_uid, cpu: cpu,
                                          memory: taskValid ? task.pti_resident_size : nil, gpu: gpu,
                                          gpuClient: gpuClients.contains(pid) || supportsGPU,
                                          threads: taskValid ? Int(task.pti_threadnum) : nil))
        }
        previous = next
        return results
    }

    public static func percent(current: UInt64?, previous: UInt64?, elapsed: Double?) -> Double? {
        guard let current, let previous, let elapsed, elapsed > 0, current >= previous else { return nil }
        return Double(current - previous) / 1_000_000_000 / elapsed * 100
    }

    public static func terminate(_ process: RunningProcess, force: Bool) throws {
        guard process.canTerminate else { throw DeckError.rpc("Questo processo è protetto o appartiene a un altro utente.") }
        guard let current = bsd(process.pid), identity(process.pid, current) == process.id, current.pbi_uid == geteuid() else {
            throw DeckError.rpc("Il processo è terminato o il PID è cambiato. Aggiorna l’elenco.")
        }
        guard kill(process.pid, force ? SIGKILL : SIGTERM) == 0 else {
            let code = errno
            throw DeckError.rpc(code == EPERM ? "macOS non consente di terminare questo processo." : "Arresto non riuscito (\(code)).")
        }
    }

    private static func bsd(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return info
    }
    private static func identity(_ pid: Int32, _ bsd: proc_bsdinfo) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startedSeconds: bsd.pbi_start_tvsec, startedMicroseconds: bsd.pbi_start_tvusec)
    }
    private static func gpuTime(_ pid: Int32) -> UInt64? {
        var port: mach_port_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &port) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, port) }
        var info = task_power_info_v2()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info_v2>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(port, task_flavor_t(TASK_POWER_INFO_V2), $0, &count) }
        }
        return status == KERN_SUCCESS ? info.gpu_energy.task_gpu_utilisation : nil
    }
    private static func gpuClients() -> Set<Int32> {
        var services: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &services) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(services) }
        var result = Set<Int32>()
        while case let service = IOIteratorNext(services), service != 0 {
            defer { IOObjectRelease(service) }
            var children: io_iterator_t = 0
            guard IORegistryEntryCreateIterator(service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(children) }
            while case let child = IOIteratorNext(children), child != 0 {
                defer { IOObjectRelease(child) }
                guard let creator = IORegistryEntryCreateCFProperty(child, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { continue }
                let parts = creator.split(whereSeparator: { !$0.isNumber })
                if let first = parts.first, let pid = Int32(first) { result.insert(pid) }
            }
        }
        return result
    }
}
