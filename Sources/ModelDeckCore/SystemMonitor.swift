import Foundation
import Darwin
import IOKit
import IOKit.ps
import Metal

public actor SystemMonitor {
    private var previousCPU: [UInt64]?
    private var previousNetwork: (Double, Double, TimeInterval)?
    public init() {}

    public static func machine() -> MachineInfo {
        var info = MachineInfo()
        var size = 0
        if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 { info.chip = String(cString: buffer) }
        }
        info.performanceCores = integer("hw.perflevel0.physicalcpu")
        info.efficiencyCores = integer("hw.perflevel1.physicalcpu")
        if let gpu = MTLCreateSystemDefaultDevice() {
            info.unifiedMemory = gpu.hasUnifiedMemory
            info.metalWorkingSet = gpu.recommendedMaxWorkingSetSize > 0 ? gpu.recommendedMaxWorkingSetSize : nil
        }
        return info
    }

    private static func integer(_ key: String) -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(key, &value, &size, nil, 0) == 0 ? Int(value) : 0
    }

    public func sample() -> SystemSnapshot {
        var result = SystemSnapshot()
        var stats = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        if status == KERN_SUCCESS {
            let ticks = [UInt64(stats.cpu_ticks.0), UInt64(stats.cpu_ticks.1), UInt64(stats.cpu_ticks.2), UInt64(stats.cpu_ticks.3)]
            if let old = previousCPU {
                // CPU tick counters are 32-bit and can wrap on long-running machines.
                let delta = zip(ticks, old).map { UInt64(UInt32(truncatingIfNeeded: $0) &- UInt32(truncatingIfNeeded: $1)) }
                let total = delta.reduce(0, +)
                if total > 0 { result.cpu = Double(total - delta[Int(CPU_STATE_IDLE)]) / Double(total) * 100 }
            }
            previousCPU = ticks
        }
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vmStatus = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount) }
        }
        if vmStatus == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            result.memoryWired = UInt64(vm.wire_count) * page
            result.memoryCompressed = UInt64(vm.compressor_page_count) * page
            // Active + wired + compressed, minus purgeable pages; excludes file cache.
            let usedPages = UInt64(vm.active_count) + UInt64(vm.inactive_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
            let cachePages = UInt64(vm.external_page_count) + UInt64(vm.purgeable_count)
            result.memoryUsed = min(result.memoryTotal, (usedPages > cachePages ? usedPages - cachePages : 0) * page)
        }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 { result.swapUsed = swap.xsu_used }
        if let volume = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) {
            result.diskTotal = UInt64(max(0, volume.volumeTotalCapacity ?? 0))
            result.diskAvailable = UInt64(max(0, volume.volumeAvailableCapacity ?? 0))
        }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: result.thermal = "Normale"
        case .fair: result.thermal = "Tiepido"
        case .serious: result.thermal = "Elevato"
        case .critical: result.thermal = "Critico"
        @unknown default: result.thermal = "Sconosciuto"
        }
        if let power = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let sources = IOPSCopyPowerSourcesList(power)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let item = IOPSGetPowerSourceDescription(power, source)?.takeUnretainedValue() as? [String: Any],
                      let current = item[kIOPSCurrentCapacityKey] as? Double, let max = item[kIOPSMaxCapacityKey] as? Double, max > 0 else { continue }
                result.battery = current / max * 100
                result.charging = item[kIOPSIsChargingKey] as? Bool ?? false
                break
            }
        }
        let network = networkTotals()
        let now = ProcessInfo.processInfo.systemUptime
        if let old = previousNetwork, now > old.2, network.0 >= old.0, network.1 >= old.1 {
            result.download = (network.0 - old.0) / (now - old.2)
            result.upload = (network.1 - old.1) / (now - old.2)
        }
        previousNetwork = (network.0, network.1, now)
        result.gpu = gpuUsage()
        return result
    }

    private func networkTotals() -> (Double, Double) {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return (0, 0) }
        defer { freeifaddrs(addresses) }
        var input = 0.0, output = 0.0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let item = current.pointee
            defer { cursor = item.ifa_next }
            guard item.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), item.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  item.ifa_flags & UInt32(IFF_UP) != 0, let data = item.ifa_data else { continue }
            // Physical Ethernet/Wi-Fi only, avoiding double counting VPN and bridge traffic.
            let name = String(cString: item.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            input += Double(counters.ifi_ibytes); output += Double(counters.ifi_obytes)
        }
        return (input, output)
    }

    private func gpuUsage() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var values: [Double] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                  let value = stats["Device Utilization %"] as? NSNumber else { continue }
            values.append(min(100, max(0, value.doubleValue)))
        }
        return values.max()
    }
}
