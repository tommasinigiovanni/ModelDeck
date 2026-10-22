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
    /// Empty selects the most restrictive active quota in the provider's main bucket.
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

    public static func selectedWindow(in usage: SubscriptionUsage, id: String, provider: MenuBarMetric, now: Date = Date()) -> UsageWindow? {
        if !id.isEmpty { return usage.windows.first { $0.id == id } }
        var candidates = usage.windows
        if provider == .openAI {
            let main = usage.windows.first { $0.id == "codex-primary" || $0.id == "codex-secondary" }
                ?? usage.windows.first { $0.id.hasSuffix("-primary") }
            if let main, let suffix = ["-primary", "-secondary"].first(where: { main.id.hasSuffix($0) }) {
                let bucket = String(main.id.dropLast(suffix.count))
                candidates = usage.windows.filter { $0.id == bucket + "-primary" || $0.id == bucket + "-secondary" }
            }
        }
        func valid(_ window: UsageWindow) -> Bool { window.usedPercent.isFinite && window.usedPercent >= 0 && (window.resetsAt.map { $0 > now } ?? true) }
        let active = candidates.filter(valid).sorted {
            if $0.usedPercent != $1.usedPercent { return $0.usedPercent > $1.usedPercent }
            return ($0.durationMinutes ?? Int.max) < ($1.durationMinutes ?? Int.max)
        }
        // A known exhausted window blocks usage even if another window needs refreshing.
        if let restrictive = active.first, restrictive.usedPercent >= 100 { return restrictive }
        // Otherwise, an expired/invalid window makes the effective remaining quota unknown.
        if let unknown = candidates.first(where: { !valid($0) }) { return unknown }
        return active.first ?? candidates.first
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
                let window = selectedWindow(in: usage, id: id, provider: metric, now: now)
                let prefix = metric == .claude ? "Claude" : "OpenAI"
                var scope = ""
                if let minutes = window?.durationMinutes, minutes > 0 {
                    scope = minutes % 1440 == 0 ? "\(minutes / 1440)g" : minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
                }
                let label = prefix + (scope.isEmpty ? "" : " " + scope)
                guard let window, window.usedPercent.isFinite, window.usedPercent >= 0,
                      window.resetsAt.map({ $0 > now }) ?? true else {
                    titles.append(label + " —")
                    details.append(metric.title + " · " + (window?.title ?? "quota selezionata") + " · non disponibile o in attesa di aggiornamento")
                    continue
                }
                let stale = usage.updatedAt.map { now.timeIntervalSince($0) > 600 } ?? true
                let needsUpdate = stale || usage.message != nil
                let value = options.quotaStyle == .used ? window.usedPercent : max(0, 100 - window.usedPercent)
                titles.append(label + " " + percentage(value) + (needsUpdate ? "*" : "") + (options.quotaStyle == .used ? " usato" : " rimanente"))
                var detail = metric.title + " · " + window.title + " · " + percentage(value) + (options.quotaStyle == .used ? " utilizzato" : " rimanente")
                if needsUpdate { detail += " · ultimo dato, da aggiornare" }
                if let reset = window.resetsAt { detail += " · reset " + reset.formatted(date: .abbreviated, time: .shortened) }
                details.append(detail)
            }
        }
        return MenuBarSummary(title: titles.joined(separator: "   "), tooltip: details.joined(separator: "\n"))
    }
}
