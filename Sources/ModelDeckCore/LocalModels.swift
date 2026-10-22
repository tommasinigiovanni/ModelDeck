import Foundation

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
}

public actor ModelInventory {
    public init() {}

    public func scan(ollamaURL: String, lmStudioURL: String, lmToken: String? = nil, folders: [String]) async -> Inventory {
        async let ollama = fetchOllama(ollamaURL)
        async let lm = fetchLMStudio(lmStudioURL, token: lmToken)
        let (o, l) = await (ollama, lm)
        var result = Inventory()
        result.models = o.0 + l.0
        result.runtimes = [o.1, l.1]
        let home = FileManager.default.homeDirectoryForCurrentUser
        if !o.1.online { result.models += Self.scanOllama(root: home.appendingPathComponent(".ollama/models")) }
        if !l.1.online {
            for relative in [".lmstudio/models", ".cache/lm-studio/models"] {
                result.models += Self.scanFolder(home.appendingPathComponent(relative), source: .lmStudio)
            }
        }
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
        var models: [LocalModel] = [], mlx: [URL: UInt64] = [:]
        var count = 0
        for case let file as URL in enumerator {
            count += 1
            if count > 50_000 { break }
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            let bytes = UInt64(max(0, values.fileSize ?? 0))
            if file.pathExtension.lowercased() == "gguf", !file.lastPathComponent.lowercased().hasPrefix("mmproj") {
                models.append(LocalModel(id: file.path, name: file.deletingPathExtension().lastPathComponent, source: source, bytes: bytes, path: file))
            } else if file.pathExtension == "safetensors" {
                mlx[file.deletingLastPathComponent(), default: 0] += bytes
            }
        }
        for (directory, bytes) in mlx {
            guard fm.fileExists(atPath: directory.appendingPathComponent("config.json").path) else { continue }
            models.append(LocalModel(id: directory.path, name: directory.lastPathComponent, source: source, bytes: bytes, format: "Safetensors", path: directory))
        }
        return models
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
