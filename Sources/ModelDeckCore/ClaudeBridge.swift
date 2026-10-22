import Foundation

public enum ClaudeBridge {
    public static var defaultSettings: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json") }
    public static var defaultState: URL { DeckPaths.support.appendingPathComponent("claude-bridge.json") }
    public static func quote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func isInstalled(settings: URL = defaultSettings, state: URL = defaultState) -> Bool {
        guard let saved = try? dictionary(state), let expected = saved["command"] as? String,
              let current = try? dictionary(settings), let line = current["statusLine"] as? [String: Any] else { return false }
        return line["command"] as? String == expected
    }

    public static func install(executable: URL, settings: URL = defaultSettings, state: URL = defaultState) throws {
        if isInstalled(settings: settings, state: state) { return }
        // A stale bridge state requires explicit restoration before another installation.
        guard !FileManager.default.fileExists(atPath: state.path) else { throw DeckError.rpc("La status line è cambiata. Ripristina il collegamento precedente prima di reinstallarlo.") }
        var root = FileManager.default.fileExists(atPath: settings.path) ? try dictionary(settings) : [:]
        let previous = root["statusLine"]
        if let previous, !(previous is [String: Any]) { throw DeckError.rpc("Formato statusLine non supportato. Nessuna modifica eseguita.") }
        var line = previous as? [String: Any] ?? [:]
        if let type = line["type"] as? String, type != "command" { throw DeckError.rpc("Tipo statusLine non supportato.") }
        let oldCommand = line["command"] as? String
        var command = quote(executable.path) + " --claude-statusline"
        if let oldCommand, !oldCommand.isEmpty { command += " --previous " + quote(oldCommand) }
        line["type"] = "command"; line["command"] = command
        let saved: [String: Any] = ["command": command, "previous": previous ?? NSNull()]
        try write(saved, to: state)
        root["statusLine"] = line
        do { try write(root, to: settings) }
        catch { try? FileManager.default.removeItem(at: state); throw error }
    }

    public static func uninstall(settings: URL = defaultSettings, state: URL = defaultState) throws {
        let saved = try dictionary(state)
        var root = try dictionary(settings)
        guard let current = root["statusLine"] as? [String: Any], current["command"] as? String == saved["command"] as? String else {
            throw DeckError.rpc("La status line è stata modificata dopo il collegamento. Il backup resta in Application Support/ModelDeck/claude-bridge.json.")
        }
        if saved["previous"] is NSNull { root.removeValue(forKey: "statusLine") }
        else { root["statusLine"] = saved["previous"] }
        try write(root, to: settings)
        try FileManager.default.removeItem(at: state)
    }

    private static func dictionary(_ url: URL) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw DeckError.invalidResponse }
        return root
    }
    private static func write(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
