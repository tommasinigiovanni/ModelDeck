import Foundation
import SQLite3

public enum DeckError: LocalizedError {
    case invalidEndpoint, http(Int), invalidResponse, missingCodex, timeout, rpc(String)
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Usa un indirizzo locale http://127.0.0.1:porta."
        case .http(let code): return code == 401 ? "Autenticazione richiesta dal server." : "Il server ha risposto HTTP \(code)."
        case .invalidResponse: return "Formato della risposta non riconosciuto."
        case .missingCodex: return "Installa Codex CLI e accedi con codex login."
        case .timeout: return "Il servizio non ha risposto in tempo."
        case .rpc(let message): return message
        }
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public enum LocalHTTP {
    public static func endpoint(_ string: String) throws -> URL {
        guard let url = URL(string: string), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw DeckError.invalidEndpoint }
        return url
    }

    static func get(_ base: URL, _ path: String, token: String? = nil) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3; config.timeoutIntervalForResource = 4
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: base.appendingPathComponent(path))
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw DeckError.invalidResponse }
        guard response.statusCode == 200 else { throw DeckError.http(response.statusCode) }
        return data
    }
    static func modelDetails(_ base: URL, name: String) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3; config.timeoutIntervalForResource = 4; config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: base.appendingPathComponent("api/show")); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": name, "verbose": false])
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_097_152 else { throw DeckError.invalidResponse }
        return data
    }
}

public actor ModelInventory {
    public init() {}

    public func scan(ollamaURL: String, lmStudioURL: String, lmToken: String? = nil, folders: [String], unslothURL: String = "http://127.0.0.1:8888", unslothToken: String? = nil, unslothFolders: [String] = []) async -> Inventory {
        async let ollama = fetchOllama(ollamaURL)
        async let lm = fetchLMStudio(lmStudioURL, token: lmToken)
        async let unsloth = fetchUnsloth(unslothURL, token: unslothToken)
        let (o, l, u) = await (ollama, lm, unsloth)
        var result = Inventory()
        result.models = o.0 + l.0 + u.0
        result.runtimes = [o.1, l.1, u.1]
        let home = FileManager.default.homeDirectoryForCurrentUser
        if !o.1.online { result.models += Self.scanOllama(root: home.appendingPathComponent(".ollama/models")) }
        if !l.1.online {
            for relative in [".lmstudio/models", ".cache/lm-studio/models"] {
                result.models += Self.scanFolder(home.appendingPathComponent(relative), source: .lmStudio)
            }
        }
        var unslothOffline: [LocalModel] = []
        for relative in [".unsloth/studio/models", ".unsloth/studio/library", ".unsloth/studio/outputs", ".unsloth/studio/exports"] {
            unslothOffline += Self.scanFolder(home.appendingPathComponent(relative), source: .unsloth)
        }
        unslothOffline += Self.scanHuggingFace(home.appendingPathComponent(".cache/huggingface/hub"))
        let remembered = Self.unslothModelDirectories(database: home.appendingPathComponent(".unsloth/studio/studio.db"))
        for folder in Array(Set(unslothFolders + remembered)) where !folder.isEmpty {
            let root = URL(fileURLWithPath: NSString(string: folder).expandingTildeInPath)
            unslothOffline += Self.scanHuggingFace(root)
            unslothOffline += Self.scanHuggingFace(root.appendingPathComponent("hub"))
            unslothOffline += Self.scanFolder(root, source: .unsloth)
        }
        let published = Set(u.0.map { $0.name.lowercased() })
        result.models += unslothOffline.filter { !published.contains($0.name.lowercased()) }
        for folder in folders where !folder.isEmpty {
            result.models += Self.scanFolder(URL(fileURLWithPath: NSString(string: folder).expandingTildeInPath), source: .folder)
        }
        var seen = Set<String>()
        result.models = result.models.filter { seen.insert($0.path?.standardizedFileURL.path ?? $0.id).inserted }
            .sorted { ($0.loaded == true ? 0 : 1, $0.name.localizedLowercase) < ($1.loaded == true ? 0 : 1, $1.name.localizedLowercase) }
        return result
    }

    private func fetchOllama(_ endpoint: String) async -> ([LocalModel], RuntimeStatus) {
        do {
            let base = try LocalHTTP.endpoint(endpoint)
            let tags = try await LocalHTTP.get(base, "api/tags")
            let running = try? await LocalHTTP.get(base, "api/ps")
            let models = try Self.parseOllama(tags: tags, running: running)
            return (models, RuntimeStatus(name: "Ollama", online: true, detail: "\(models.count) modelli · API locale"))
        } catch {
            return ([], RuntimeStatus(name: "Ollama", online: false, detail: error is DeckError ? error.localizedDescription : "Server spento · lettura da disco"))
        }
    }

    private func fetchLMStudio(_ endpoint: String, token: String?) async -> ([LocalModel], RuntimeStatus) {
        do {
            let base = try LocalHTTP.endpoint(endpoint)
            let data: Data
            do { data = try await LocalHTTP.get(base, "api/v1/models", token: token) }
            catch DeckError.http(404) { data = try await LocalHTTP.get(base, "api/v0/models", token: token) }
            let models = try Self.parseLMStudio(data)
            return (models, RuntimeStatus(name: "LM Studio", online: true, detail: "\(models.count) modelli · API locale"))
        } catch {
            return ([], RuntimeStatus(name: "LM Studio", online: false, detail: error is DeckError ? error.localizedDescription : "Server spento · lettura da disco"))
        }
    }

    private func fetchUnsloth(_ endpoint: String, token: String?) async -> ([LocalModel], RuntimeStatus) {
        do {
            let base = try LocalHTTP.endpoint(endpoint)
            let data = try await LocalHTTP.get(base, "v1/models", token: token)
            let live = try? await LocalHTTP.get(base, "api/inference/loaded-models", token: token)
            let models = try Self.parseUnsloth(data, running: live)
            return (models, RuntimeStatus(name: "Unsloth", online: true, detail: "\(models.count) modelli · API locale"))
        } catch {
            return ([], RuntimeStatus(name: "Unsloth", online: false, detail: error is DeckError ? error.localizedDescription : "Server spento · cache e cartelle locali"))
        }
    }

    public static func parseUnsloth(_ data: Data, running: Data?) throws -> [LocalModel] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let items = root["data"] as? [[String: Any]] else { throw DeckError.invalidResponse }
        let liveRoot = running.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let live = liveRoot?["data"] as? [[String: Any]]
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let active = live?.contains { ($0["id"] as? String) == id && ($0["loaded"] as? Bool) != false }
            return LocalModel(id: "unsloth:\(id)", name: id, source: .unsloth,
                              bytes: (item["size_bytes"] as? NSNumber)?.uint64Value ?? 0,
                              format: (item["format"] as? String ?? "—").uppercased(),
                              quantization: item["quantization"] as? String,
                              context: item["context_length"] as? Int,
                              loaded: active ?? item["loaded"] as? Bool)
        }
    }

    public static func parseOllama(tags: Data, running: Data?) throws -> [LocalModel] {
        guard let root = try JSONSerialization.jsonObject(with: tags) as? [String: Any], let items = root["models"] as? [[String: Any]] else { throw DeckError.invalidResponse }
        let live = running.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["models"] as? [[String: Any]]
        return items.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let details = item["details"] as? [String: Any] ?? [:]
            let active = live?.first { ($0["name"] as? String ?? $0["model"] as? String) == name }
            return LocalModel(id: "ollama:\(name)", name: name, source: .ollama,
                              bytes: (item["size"] as? NSNumber)?.uint64Value ?? 0,
                              format: (details["format"] as? String ?? "gguf").uppercased(),
                              quantization: details["quantization_level"] as? String, parameters: details["parameter_size"] as? String,
                              context: active?["context_length"] as? Int, loaded: live == nil ? nil : active != nil,
                              vram: (active?["size_vram"] as? NSNumber)?.uint64Value)
        }
    }

    public static func parseLMStudio(_ data: Data) throws -> [LocalModel] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = (root["models"] ?? root["data"]) as? [[String: Any]] else { throw DeckError.invalidResponse }
        return items.compactMap { item in
            guard let key = item["key"] as? String ?? item["id"] as? String else { return nil }
            let quant = item["quantization"] as? [String: Any]
            let instances = item["loaded_instances"] as? [[String: Any]]
            let loaded: Bool? = instances.map { !$0.isEmpty } ?? (item["state"] as? String).map { $0 == "loaded" }
            return LocalModel(id: "lm:\(key)", name: item["display_name"] as? String ?? key, source: .lmStudio,
                              bytes: (item["size_bytes"] as? NSNumber)?.uint64Value ?? 0,
                              format: (item["format"] as? String ?? item["compatibility_type"] as? String ?? "—").uppercased(),
                              quantization: quant?["name"] as? String ?? item["quantization"] as? String,
                              parameters: item["params_string"] as? String, context: item["max_context_length"] as? Int, loaded: loaded)
        }
    }

    public static func scanFolder(_ folder: URL, source: ModelSource) -> [LocalModel] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var models: [LocalModel] = [], tensors: [URL: [(String, UInt64)]] = [:]
        var shards: [String: [(index: Int, count: Int, bytes: UInt64, path: URL)]] = [:]
        let splitPattern = try! NSRegularExpression(pattern: "^(.*)-([0-9]{5})-of-([0-9]{5})\\.gguf$", options: .caseInsensitive)
        var count = 0
        for case let file as URL in enumerator {
            count += 1
            if count > 50_000 { break }
            let target = file.resolvingSymlinksInPath()
            guard let values = try? target.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            let bytes = UInt64(max(0, values.fileSize ?? 0))
            let name = file.lastPathComponent, lower = name.lowercased()
            if file.pathExtension.lowercased() == "gguf", bytes > 0, !lower.contains("mmproj"), !lower.hasPrefix("mtp-"), !lower.contains("-lora.") {
                if let match = splitPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                   let baseRange = Range(match.range(at: 1), in: name), let indexRange = Range(match.range(at: 2), in: name), let countRange = Range(match.range(at: 3), in: name),
                   let index = Int(name[indexRange]), let count = Int(name[countRange]) {
                    let key = file.deletingLastPathComponent().appendingPathComponent(String(name[baseRange])).path
                    shards[key, default: []].append((index, count, bytes, file))
                } else {
                    models.append(LocalModel(id: file.path, name: file.deletingPathExtension().lastPathComponent, source: source, bytes: bytes, path: file))
                }
            } else if file.pathExtension.lowercased() == "safetensors", !lower.hasPrefix("adapter_") {
                tensors[file.deletingLastPathComponent(), default: []].append((name, bytes))
            }
        }
        for (base, parts) in shards {
            guard let count = parts.first?.count, count > 0, count < 10_000, parts.count == count,
                  parts.allSatisfy({ $0.count == count }), Set(parts.map(\.index)) == Set(1...count),
                  let first = parts.first(where: { $0.index == 1 }) else { continue }
            models.append(LocalModel(id: base, name: (base as NSString).lastPathComponent + " · \(count) parti", source: source,
                                     bytes: sumWeightSizes(parts.map(\.bytes)), path: first.path))
        }
        let tensorPattern = try! NSRegularExpression(pattern: "-([0-9]{5})-of-([0-9]{5})\\.safetensors$", options: .caseInsensitive)
        for (directory, sizes) in tensors {
            guard fm.fileExists(atPath: directory.appendingPathComponent("config.json").path) else { continue }
            let indexed: [(Int, Int)] = sizes.compactMap { name, _ in
                guard let match = tensorPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                      let a = Range(match.range(at: 1), in: name), let b = Range(match.range(at: 2), in: name),
                      let index = Int(name[a]), let count = Int(name[b]) else { return nil }
                return (index, count)
            }
            if let count = indexed.first?.1 {
                guard count > 0, count < 10_000, indexed.count == count, indexed.allSatisfy({ $0.1 == count }), Set(indexed.map(\.0)) == Set(1...count) else { continue }
            }
            models.append(LocalModel(id: directory.path, name: directory.lastPathComponent, source: source, bytes: sumWeightSizes(sizes.map(\.1)), format: "Safetensors", path: directory))
        }
        return models
    }

    private static func sumWeightSizes(_ sizes: [UInt64]) -> UInt64 {
        sizes.reduce(0) { total, size in let (sum, overflow) = total.addingReportingOverflow(size); return overflow ? UInt64.max : sum }
    }

    public static func scanHuggingFace(_ root: URL) -> [LocalModel] {
        let fm = FileManager.default
        guard let repos = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return [] }
        var result: [LocalModel] = []
        for repo in repos where repo.lastPathComponent.hasPrefix("models--") {
            let name = String(repo.lastPathComponent.dropFirst(8)).replacingOccurrences(of: "--", with: "/")
            let snapshots = repo.appendingPathComponent("snapshots")
            let revisions = (try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            let ref = (try? String(contentsOf: repo.appendingPathComponent("refs/main"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let chosen = revisions.first { $0.lastPathComponent == ref }.map { [$0] } ?? revisions
            for revision in chosen {
                var models = scanFolder(revision, source: .unsloth)
                for index in models.indices {
                    models[index].name = models[index].format == "GGUF" ? name + " / " + models[index].name : name
                }
                result += models
            }
        }
        return result
    }

    /// Reads only three model-directory preferences. Never opens auth databases or chat tables.
    /// Immutable read mode avoids creating sidecars in another application's storage.
    public static func unslothModelDirectories(database: URL) -> [String] {
        guard FileManager.default.fileExists(atPath: database.path) else { return [] }
        let uri = "file:" + (database.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? database.path) + "?mode=ro&immutable=1"
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)
        var statement: OpaquePointer?
        let query = "SELECT value_json FROM app_settings WHERE key IN ('hugging_face_cache_home','hugging_face_cache_history','hugging_face_download_homes')"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var paths: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            let data = Data(String(cString: text).utf8)
            guard let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { continue }
            if let path = value as? String { paths.append(path) }
            if let list = value as? [String] { paths += list }
        }
        return Array(Set(paths.filter { $0.hasPrefix("/") || $0.hasPrefix("~/") })).sorted()
    }

    public static func scanOllama(root: URL) -> [LocalModel] {
        let manifests = root.appendingPathComponent("manifests")
        guard let enumerator = FileManager.default.enumerator(at: manifests, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles) else { return [] }
        var result: [LocalModel] = []
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let layers = json["layers"] as? [[String: Any]] else { continue }
            let relative = String(file.path.dropFirst(manifests.path.count + 1)).split(separator: "/").map(String.init)
            guard relative.count >= 3 else { continue }
            let name = relative.dropFirst().dropLast().joined(separator: "/") + ":" + (relative.last ?? "latest")
            let bytes = layers.filter { ($0["mediaType"] as? String)?.contains("model") == true }.reduce(UInt64(0)) { $0 + (($1["size"] as? NSNumber)?.uint64Value ?? 0) }
            result.append(LocalModel(id: "ollama:\(name)", name: name, source: .ollama, bytes: bytes, path: file))
        }
        return result
    }
}
