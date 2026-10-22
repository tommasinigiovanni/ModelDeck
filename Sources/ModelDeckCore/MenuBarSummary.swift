import Foundation

public enum MenuBarMetric: String, CaseIterable, Codable, Sendable {
    case cpu, memory, gpu, claude, openAI
    public var title: String {
        switch self { case .cpu: "CPU"; case .memory: "RAM"; case .gpu: "GPU"; case .claude: "Claude"; case .openAI: "OpenAI (Codex)" }
    }
}

public enum MenuBarMemoryStyle: String, CaseIterable, Codable, Sendable {
    case percent, used
    public var title: String { self == .percent ? "Percentuale" : "Memoria utilizzata" }
}

public enum MenuBarQuotaStyle: String, CaseIterable, Codable, Sendable {
    case used, remaining
    public var title: String { self == .used ? "Utilizzata" : "Rimanente" }
}

public struct MenuBarOptions: Codable, Equatable, Sendable {
    public static let defaultsKey = "menuBarOptions"
    public var metrics: Set<MenuBarMetric> = [.cpu, .memory]
    public var memoryStyle: MenuBarMemoryStyle = .percent
    public var quotaStyle: MenuBarQuotaStyle = .used
    /// Empty selects the provider's main quota. Explicit IDs never fall back to a different window.
    public var claudeWindowID = ""
    public var openAIWindowID = ""
    public init() {}
    public var encoded: String { (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "" }
    public static func decode(_ raw: String?) -> MenuBarOptions {
        guard let raw, let data = raw.data(using: .utf8), let options = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return options
    }
    public static func load(from defaults: UserDefaults = .standard) -> MenuBarOptions { decode(defaults.string(forKey: defaultsKey)) }
}

public struct MenuBarSummary: Sendable {
    public let title: String
    public let tooltip: String

    public static func selectedWindow(in usage: SubscriptionUsage, id: String, provider: MenuBarMetric) -> UsageWindow? {
        if !id.isEmpty { return usage.windows.first { $0.id == id } }
        let main = provider == .claude ? "five_hour" : "codex-primary"
        return usage.windows.first { $0.id == main } ?? usage.windows.first { $0.id.hasSuffix("-primary") } ?? usage.windows.first
    }

    public static func render(options: MenuBarOptions, snapshot: SystemSnapshot, claude: SubscriptionUsage, openAI: SubscriptionUsage, now: Date = Date()) -> MenuBarSummary {
        var titles: [String] = [], details = ["ModelDeck"]
        func percentage(_ value: Double?) -> String {
            guard let value, value.isFinite, value >= 0 else { return "—" }
            return DeckFormat.percent(value)
        }
        for metric in MenuBarMetric.allCases where options.metrics.contains(metric) {
            switch metric {
            case .cpu, .gpu:
                let value = percentage(metric == .cpu ? snapshot.cpu : snapshot.gpu)
                titles.append(metric.title + " " + value)
                details.append(metric.title + " · " + value)
            case .memory:
                let available = snapshot.memoryTotal > 0 && snapshot.memoryUsed > 0
                let value = available ? options.memoryStyle == .percent ? percentage(snapshot.memoryPercent) : DeckFormat.bytes(snapshot.memoryUsed) : "—"
                titles.append("RAM " + value)
                details.append(available ? "RAM · \(DeckFormat.bytes(snapshot.memoryUsed)) / \(DeckFormat.bytes(snapshot.memoryTotal)) · \(percentage(snapshot.memoryPercent))" : "RAM · non disponibile")
            case .claude, .openAI:
                let usage = metric == .claude ? claude : openAI
                let id = metric == .claude ? options.claudeWindowID : options.openAIWindowID
                let window = selectedWindow(in: usage, id: id, provider: metric)
                let prefix = metric == .claude ? "CL" : "OA"
                var scope = ""
                if let minutes = window?.durationMinutes, minutes > 0 {
                    scope = minutes % 1440 == 0 ? "\(minutes / 1440)g" : minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
                }
                let label = prefix + scope
                guard let window, window.usedPercent.isFinite, window.usedPercent >= 0,
                      window.resetsAt.map({ $0 > now }) ?? true else {
                    titles.append(label + " —")
                    details.append(metric.title + " · " + (window?.title ?? "quota selezionata") + " · non disponibile o in attesa di aggiornamento")
                    continue
                }
                let stale = usage.updatedAt.map { now.timeIntervalSince($0) > 600 } ?? true
                let needsUpdate = stale || usage.message != nil
                let value = options.quotaStyle == .used ? window.usedPercent : max(0, 100 - window.usedPercent)
                titles.append(label + " " + percentage(value) + (needsUpdate ? "*" : ""))
                var detail = metric.title + " · " + window.title + " · " + percentage(value) + (options.quotaStyle == .used ? " utilizzato" : " rimanente")
                if needsUpdate { detail += " · ultimo dato, da aggiornare" }
                if let reset = window.resetsAt { detail += " · reset " + reset.formatted(date: .abbreviated, time: .shortened) }
                details.append(detail)
            }
        }
        return MenuBarSummary(title: titles.joined(separator: "   "), tooltip: details.joined(separator: "\n"))
    }
}
