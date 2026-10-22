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
    private let monitor = SystemMonitor()
    private let scanner = ModelInventory()
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
                                       lmToken: DeckKeychain.read(), folders: defaults.stringArray(forKey: "modelFolders") ?? [])
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
    func useDemo() {
        demo = true
        machine.chip = "Apple M4 Pro"; machine.memory = 48_000_000_000; machine.cores = 12
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
            LocalModel(id: "d", name: "nomic-embed-text:latest", source: .ollama, bytes: 274_000_000, parameters: "137M", loaded: false)
        ]
        inventory.runtimes = [.init(name: "Ollama", online: true, detail: "2 modelli · API locale"), .init(name: "LM Studio", online: true, detail: "2 modelli · API locale")]
        codex = .init(provider: "OpenAI", plan: "Pro", windows: [.init(id: "h", title: "5 ore", usedPercent: 34, resetsAt: Date().addingTimeInterval(9500)), .init(id: "w", title: "7 giorni", usedPercent: 58, resetsAt: Date().addingTimeInterval(240000))], updatedAt: Date(), source: "Codex · app server")
        claude = .init(provider: "Claude", windows: [.init(id: "h", title: "5 ore", usedPercent: 23, resetsAt: Date().addingTimeInterval(7200)), .init(id: "w", title: "7 giorni", usedPercent: 41, resetsAt: Date().addingTimeInterval(180000))], updatedAt: Date(), source: "Claude Code · status line")
    }
}

enum DeckKeychain {
    static let service = "io.github.tommasinigiovanni.ModelDeck"
    static func read() -> String? {
        var value: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "lmstudio", kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &value)
        guard status == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String) throws {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "lmstudio"] as [CFString: Any]
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
