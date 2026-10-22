import SwiftUI
import ModelDeckCore
import Security

@MainActor final class DeckStore: ObservableObject {
    @Published var snapshot = SystemSnapshot()
    @Published var machine = SystemMonitor.machine()
    @Published var inventory = Inventory()
    @Published var codex = SubscriptionUsage(provider: "OpenAI", source: "Codex · app server", message: "Lettura quote…")
    @Published var claude = ClaudeUsage.read()
    @Published var cpuHistory: [Double] = []
    @Published var memoryHistory: [Double] = []
    @Published var gpuHistory: [Double] = []
    @Published var refreshing = false
    @Published var usageRefreshing = false
    @Published var lastInventory: Date?
    @Published var settingsMessage: String?
    @Published var demo = false
    @Published var processes: [RunningProcess] = []
    private let monitor = SystemMonitor()
    private let scanner = ModelInventory()
    private let processMonitor = ProcessMonitor()
    private var started = false

    func start() {
        guard !started, !demo else { return }; started = true
        Task { [weak self] in
            while !Task.isCancelled, let self {
                snapshot = await monitor.sample()
                if let value = snapshot.cpu { append(value, to: &cpuHistory) }
                if let value = snapshot.gpu { append(value, to: &gpuHistory) }
                append(snapshot.memoryPercent, to: &memoryHistory)
                claude = ClaudeUsage.read()
                let interval = max(2, UserDefaults.standard.double(forKey: "sampleInterval"))
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        Task { [weak self] in
            while !Task.isCancelled, let self { await refreshModels(); try? await Task.sleep(for: .seconds(30)) }
        }
        Task { [weak self] in
            while !Task.isCancelled, let self { await refreshUsage(); try? await Task.sleep(for: .seconds(90)) }
        }
    }
    private func append(_ value: Double, to history: inout [Double]) {
        history.append(value); if history.count > 90 { history.removeFirst(history.count - 90) }
    }
    func refreshModels() async {
        guard !refreshing, !demo else { return }; refreshing = true
        defer { refreshing = false }
        let defaults = UserDefaults.standard
        inventory = await scanner.scan(ollamaURL: defaults.string(forKey: "ollamaURL") ?? "http://127.0.0.1:11434",
                                       lmStudioURL: defaults.string(forKey: "lmStudioURL") ?? "http://127.0.0.1:1234",
                                       lmToken: DeckKeychain.read(), folders: defaults.stringArray(forKey: "modelFolders") ?? [],
                                       unslothURL: defaults.string(forKey: "unslothURL") ?? "http://127.0.0.1:8888",
                                       unslothToken: DeckKeychain.read(account: "unsloth"), unslothFolders: defaults.stringArray(forKey: "unslothFolders") ?? [])
        lastInventory = Date()
    }
    func refreshUsage() async {
        guard !usageRefreshing, !demo else { return }; usageRefreshing = true
        defer { usageRefreshing = false }
        do { codex = try await CodexUsage.read() }
        catch {
            // Keep last-known values with their original timestamp; never turn an error into 0%.
            codex.message = error.localizedDescription
        }
        claude = ClaudeUsage.read()
    }
    func refreshProcesses() async {
        guard !demo else { return }
        processes = await processMonitor.sample()
    }
    func useDemo() {
        demo = true
        machine.chip = "Apple M4 Pro"; machine.memory = 48_000_000_000; machine.cores = 12
        machine.unifiedMemory = true; machine.metalWorkingSet = 36_000_000_000
        snapshot.cpu = 33; snapshot.gpu = 72; snapshot.memoryTotal = machine.memory
        snapshot.memoryUsed = 36_800_000_000; snapshot.swapUsed = 6_500_000_000
        snapshot.diskTotal = 2_000_000_000_000; snapshot.diskAvailable = 1_021_000_000_000
        snapshot.download = 2_600_000; snapshot.upload = 174_000; snapshot.battery = 84
        cpuHistory = (0..<70).map { index -> Double in
            let x = Double(index)
            let base = 25.0 + sin(x * 0.27) * 13.0
            return base + sin(x * 1.7) * 4.0
        }
        memoryHistory = (0..<70).map { index -> Double in 74.0 + Double(index) / 25.0 + sin(Double(index) * 0.2) }
        gpuHistory = (0..<70).map { index -> Double in 55.0 + sin(Double(index) * 0.35) * 25.0 }
        inventory.models = [
            LocalModel(id: "a", name: "Qwen3.5 27B", source: .lmStudio, bytes: 21_200_000_000, quantization: "Q6_K", parameters: "27B", context: 262144, loaded: true),
            LocalModel(id: "b", name: "gpt-oss:20b", source: .ollama, bytes: 13_800_000_000, quantization: "MXFP4", parameters: "20B", loaded: false),
            LocalModel(id: "c", name: "Gemma 3 12B Instruct", source: .lmStudio, bytes: 8_100_000_000, quantization: "Q4_K_M", parameters: "12B", loaded: false),
            LocalModel(id: "d", name: "nomic-embed-text:latest", source: .ollama, bytes: 274_000_000, parameters: "137M", loaded: false),
            LocalModel(id: "e", name: "unsloth / Qwen3.5 9B", source: .unsloth, bytes: 6_300_000_000, quantization: "Q4_K_M", parameters: "9B", loaded: false)
        ]
        processes = [
            RunningProcess(id: .init(pid: 101, startedSeconds: 1, startedMicroseconds: 0), name: "Local Inference", path: "/Applications/Local Inference.app", userID: 501, cpu: 154, memory: 8_400_000_000, gpu: 65, gpuClient: true, threads: 24),
            RunningProcess(id: .init(pid: 102, startedSeconds: 1, startedMicroseconds: 0), name: "Editor", path: "/Applications/Editor.app", userID: 501, cpu: 28, memory: 1_200_000_000, gpu: nil, gpuClient: true, threads: 12),
            RunningProcess(id: .init(pid: 103, startedSeconds: 1, startedMicroseconds: 0), name: "Browser", path: "/Applications/Browser.app", userID: 501, cpu: 16, memory: 2_600_000_000, gpu: nil, gpuClient: true, threads: 18)
        ]
        inventory.runtimes = [.init(name: "Ollama", online: true, detail: "2 modelli · API locale"), .init(name: "LM Studio", online: true, detail: "2 modelli · API locale")]
        codex = .init(provider: "OpenAI", plan: "Pro", windows: [.init(id: "codex-primary", title: "5 ore", usedPercent: 34, resetsAt: Date().addingTimeInterval(9500), durationMinutes: 300), .init(id: "codex-secondary", title: "7 giorni", usedPercent: 58, resetsAt: Date().addingTimeInterval(240000), durationMinutes: 10080)], updatedAt: Date(), source: "Codex · app server")
        claude = .init(provider: "Claude", windows: [.init(id: "five_hour", title: "5 ore", usedPercent: 23, resetsAt: Date().addingTimeInterval(7200), durationMinutes: 300), .init(id: "seven_day", title: "7 giorni", usedPercent: 41, resetsAt: Date().addingTimeInterval(180000), durationMinutes: 10080)], updatedAt: Date(), source: "Claude Code · status line")
    }
}

enum DeckKeychain {
    static let service = "io.github.tommasinigiovanni.ModelDeck"
    static func read(account: String = "lmstudio") -> String? {
        var value: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &value)
        guard status == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String, account: String = "lmstudio") throws {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as [CFString: Any]
        if token.isEmpty { SecItemDelete(query as CFDictionary); return }
        let attributes = [kSecValueData: Data(token.utf8)] as [CFString: Any]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData] = Data(token.utf8); item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw DeckError.rpc("Impossibile salvare il token nel Portachiavi (\(added)).") }
        } else if status != errSecSuccess { throw DeckError.rpc("Impossibile aggiornare il Portachiavi (\(status)).") }
    }
}
