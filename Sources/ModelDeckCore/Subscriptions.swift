import Foundation
import Darwin

public enum CodexUsage {
    public static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Starts only an account reader. Never creates a thread, turn, or model request.
    public static func read(executableURL: URL? = nil) async throws -> SubscriptionUsage {
        try await Task.detached(priority: .utility) { try readBlocking(executableURL: executableURL) }.value
    }

    private static func readBlocking(executableURL: URL?) throws -> SubscriptionUsage {
        // A terminated CLI must surface as a write error instead of killing the app.
        signal(SIGPIPE, SIG_IGN)
        guard let executable = executableURL ?? executable() else { throw DeckError.missingCodex }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable; process.arguments = ["app-server"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        try process.run()
        let deadline = DispatchWorkItem {
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: deadline)
        defer {
            deadline.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
        }
        func send(_ object: [String: Any]) throws {
            var bytes = try JSONSerialization.data(withJSONObject: object)
            bytes.append(0x0a)
            try input.fileHandleForWriting.write(contentsOf: bytes)
        }
        var buffer = Data()
        func response(_ id: Int) throws -> [String: Any] {
            while true {
                while let newline = buffer.firstIndex(of: 0x0a) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    guard (object["id"] as? Int) == id else {
                        if let requestID = object["id"], object["method"] != nil {
                            try send(["id": requestID, "error": ["code": -32601, "message": "ModelDeck supports account reads only"]])
                        }
                        continue
                    }
                    if let error = object["error"] as? [String: Any] {
                        let code = error["code"] as? Int ?? 0
                        throw DeckError.rpc("Codex non disponibile (\(code)). Controlla codex login e aggiorna la CLI.")
                    }
                    guard let result = object["result"] as? [String: Any] else { throw DeckError.invalidResponse }
                    return result
                }
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else { throw DeckError.timeout }
                buffer.append(chunk)
                guard buffer.count < 2_000_000 else { throw DeckError.invalidResponse }
            }
        }
        try send(["id": 0, "method": "initialize", "params": ["clientInfo": ["name": "modeldeck", "title": "ModelDeck", "version": "0.4.0"]]])
        _ = try response(0)
        try send(["method": "initialized", "params": [:]])
        try send(["id": 1, "method": "account/rateLimits/read", "params": [:]])
        let result = try response(1)
        return try parse(JSONSerialization.data(withJSONObject: result))
    }

    public static func parse(_ data: Data, now: Date = Date()) throws -> SubscriptionUsage {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DeckError.invalidResponse }
        var buckets = (result["rateLimitsByLimitId"] as? [String: [String: Any]]) ?? [:]
        if buckets.isEmpty, let bucket = result["rateLimits"] as? [String: Any] { buckets[bucket["limitId"] as? String ?? "codex"] = bucket }
        var windows: [UsageWindow] = [], plan: String?
        for (key, bucket) in buckets.sorted(by: { $0.key < $1.key }) {
            plan = plan ?? bucket["planType"] as? String
            for field in ["primary", "secondary"] {
                guard let window = bucket[field] as? [String: Any], let percent = window["usedPercent"] as? Double, percent.isFinite, percent >= 0 else { continue }
                let minutes = window["windowDurationMins"] as? Int
                let duration: String
                if let minutes, minutes > 0 {
                    duration = minutes % 1440 == 0 ? "\(minutes / 1440) giorni" : minutes % 60 == 0 ? "\(minutes / 60) ore" : "\(minutes) min"
                } else { duration = field == "primary" ? "Sessione" : "Periodo esteso" }
                let name = bucket["limitName"] as? String ?? key
                windows.append(UsageWindow(id: "\(key)-\(field)", title: buckets.count > 1 ? "\(name) · \(duration)" : duration,
                                           usedPercent: percent, resetsAt: (window["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:)), durationMinutes: minutes))
            }
        }
        return SubscriptionUsage(provider: "OpenAI", plan: plan, windows: windows, updatedAt: now,
                                 source: "Codex · app server", message: windows.isEmpty ? "Nessuna quota disponibile. Accedi a Codex con il tuo piano ChatGPT." : nil)
    }
}

public enum ClaudeUsage {
    public static func read(from url: URL = DeckPaths.claudeUsage, now: Date = Date()) -> SubscriptionUsage {
        guard let data = try? Data(contentsOf: url) else {
            return SubscriptionUsage(provider: "Claude", source: "Claude Code · status line", message: "Collega Claude Code dalle impostazioni, poi invia un messaggio in una sessione.")
        }
        return (try? parse(data, now: now)) ?? SubscriptionUsage(provider: "Claude", source: "Claude Code · status line", message: "Dati non validi. Attendi un nuovo aggiornamento da Claude Code.")
    }

    public static func parse(_ data: Data, now: Date = Date()) throws -> SubscriptionUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DeckError.invalidResponse }
        let limits = root["rate_limits"] as? [String: Any] ?? [:]
        var windows: [UsageWindow] = []
        for (key, title, duration) in [("five_hour", "5 ore", 300), ("seven_day", "7 giorni", 10080), ("spend_limit", "Limite di spesa", 0)] {
            guard let item = limits[key] as? [String: Any], let percent = item["used_percentage"] as? Double, percent.isFinite, percent >= 0 else { continue }
            let reset = (item["resets_at"] as? Double).map(Date.init(timeIntervalSince1970:))
            windows.append(UsageWindow(id: key, title: title, usedPercent: percent, resetsAt: reset, durationMinutes: duration > 0 ? duration : nil))
        }
        return SubscriptionUsage(provider: "Claude", windows: windows,
                                 updatedAt: (root["updated_at"] as? Double).map(Date.init(timeIntervalSince1970:)),
                                 source: "Claude Code · status line",
                                 message: windows.isEmpty ? "Nessuna quota ricevuta. Serve un piano compatibile e una risposta in Claude Code." : nil)
    }

    /// Persists only quota fields, never prompts, transcript paths, account IDs or tokens.
    public static func capture(_ input: Data, to url: URL = DeckPaths.claudeUsage, now: Date = Date()) throws {
        guard let root = try JSONSerialization.jsonObject(with: input) as? [String: Any] else { throw DeckError.invalidResponse }
        let source = root["rate_limits"] as? [String: Any] ?? [:]
        var limits: [String: Any] = [:]
        for key in ["five_hour", "seven_day", "spend_limit"] {
            guard let item = source[key] as? [String: Any], let percent = item["used_percentage"] as? Double, percent.isFinite, percent >= 0 else { continue }
            var clean: [String: Any] = ["used_percentage": percent]
            if let reset = item["resets_at"] as? Double, reset.isFinite { clean["resets_at"] = reset }
            limits[key] = clean
        }
        // An early statusline event without quota data must not erase a valid snapshot.
        guard !limits.isEmpty else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let clean: [String: Any] = ["updated_at": now.timeIntervalSince1970, "rate_limits": limits]
        try JSONSerialization.data(withJSONObject: clean, options: .sortedKeys).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
