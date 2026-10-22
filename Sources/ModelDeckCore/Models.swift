import Foundation

public struct MachineInfo: Sendable {
    public var chip = "Mac"
    public var cores = ProcessInfo.processInfo.processorCount
    public var performanceCores = 0
    public var efficiencyCores = 0
    public var memory = ProcessInfo.processInfo.physicalMemory
    public var os = ProcessInfo.processInfo.operatingSystemVersionString
    public init() {}
}

public struct SystemSnapshot: Sendable {
    public var cpu: Double?
    public var gpu: Double?
    public var memoryUsed: UInt64 = 0
    public var memoryTotal = ProcessInfo.processInfo.physicalMemory
    public var memoryWired: UInt64 = 0
    public var memoryCompressed: UInt64 = 0
    public var swapUsed: UInt64 = 0
    public var diskTotal: UInt64 = 0
    public var diskAvailable: UInt64 = 0
    public var download: Double?
    public var upload: Double?
    public var battery: Double?
    public var charging = false
    public var thermal = "Normale"
    public var uptime = ProcessInfo.processInfo.systemUptime
    public var timestamp = Date()
    public init() {}
    public var memoryPercent: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) * 100 : 0 }
}

public enum ModelSource: String, CaseIterable, Codable, Sendable {
    case ollama = "Ollama", lmStudio = "LM Studio", folder = "Cartella"
}

public struct LocalModel: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var source: ModelSource
    public var bytes: UInt64
    public var format: String
    public var quantization: String?
    public var parameters: String?
    public var context: Int?
    /// nil means the server is unavailable and loaded state cannot be established.
    public var loaded: Bool?
    public var vram: UInt64?
    public var path: URL?
    public init(id: String, name: String, source: ModelSource, bytes: UInt64 = 0, format: String = "GGUF", quantization: String? = nil, parameters: String? = nil, context: Int? = nil, loaded: Bool? = nil, vram: UInt64? = nil, path: URL? = nil) {
        self.id = id; self.name = name; self.source = source; self.bytes = bytes
        self.format = format; self.quantization = quantization; self.parameters = parameters
        self.context = context; self.loaded = loaded; self.vram = vram; self.path = path
    }
}

public struct RuntimeStatus: Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var online: Bool
    public var detail: String
    public init(name: String, online: Bool, detail: String) { self.name = name; self.online = online; self.detail = detail }
}

public struct Inventory: Sendable {
    public var models: [LocalModel] = []
    public var runtimes: [RuntimeStatus] = []
    public var scannedAt = Date()
    public init() {}
}

public struct UsageWindow: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var isExpired: Bool { resetsAt.map { $0 <= Date() } ?? false }
    public init(id: String, title: String, usedPercent: Double, resetsAt: Date?) {
        self.id = id; self.title = title; self.usedPercent = usedPercent; self.resetsAt = resetsAt
    }
}

public struct SubscriptionUsage: Sendable {
    public var provider: String
    public var plan: String?
    public var windows: [UsageWindow] = []
    public var updatedAt: Date?
    public var source: String
    public var message: String?
    public var stale: Bool { updatedAt.map { Date().timeIntervalSince($0) > 600 } ?? true }
    public init(provider: String, plan: String? = nil, windows: [UsageWindow] = [], updatedAt: Date? = nil, source: String, message: String? = nil) {
        self.provider = provider; self.plan = plan; self.windows = windows
        self.updatedAt = updatedAt; self.source = source; self.message = message
    }
}

public enum DeckFormat {
    public static func bytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
    public static func rate(_ bytes: Double?) -> String {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return "—" }
        return self.bytes(UInt64(min(bytes, Double(Int64.max)))) + "/s"
    }
    public static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0) } ?? "—"
    }
}

public enum DeckPaths {
    public static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ModelDeck", isDirectory: true)
    }
    public static var claudeUsage: URL { support.appendingPathComponent("claude-usage.json") }
}
