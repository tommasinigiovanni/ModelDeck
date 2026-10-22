import Foundation

public struct WeightVariant: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let bytes: UInt64
    public let files: Int
    public init(name: String, bytes: UInt64, files: Int = 1) { self.name = name; self.bytes = bytes; self.files = files }
}

public struct HubModel: Sendable {
    public var repository: String
    public var revision: String
    public var variants: [WeightVariant]
    public var profile: AttentionProfile
    public var parameters: Double?
    public var baseModel: String?
}

private final class HubRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let url = request.url
        completionHandler(url?.scheme == "https" && url?.host == "huggingface.co" ? request : nil)
    }
}

public enum HuggingFaceCatalog {
    public static func repositoryID(_ input: String) throws -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("://") {
            guard let url = URL(string: text), url.scheme == "https", url.host == "huggingface.co", url.user == nil, url.password == nil, url.port == nil else { throw DeckError.rpc("Inserisci un repository Hugging Face nel formato autore/modello.") }
            text = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.count <= 128 && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            throw DeckError.rpc("Inserisci autore/modello oppure il link alla pagina del repository, senza /blob o /tree.")
        }
        return parts.joined(separator: "/")
    }

    public static func fetch(_ input: String) async throws -> HubModel {
        let id = try repositoryID(input)
        let data = try await metadata(URL(string: "https://huggingface.co/api/models/\(id)?blobs=true")!)
        var model = try parse(data, repository: id)
        let revision = model.revision.range(of: "^[a-fA-F0-9]{7,64}$", options: .regularExpression) != nil ? model.revision : "main"
        var ownProfile: AttentionProfile?
        if let config = try? await metadata(URL(string: "https://huggingface.co/\(id)/resolve/\(revision)/config.json")!, limit: 1_048_576) {
            ownProfile = try? AttentionProfile.parseConfig(config, source: "Hugging Face · \(id)/config.json")
        }
        try Task.checkCancellation()
        if let profile = ownProfile, profile.complete { model.profile = profile }
        else if let base = model.baseModel, let validBase = try? repositoryID(base), validBase != id,
                  let config = try? await metadata(URL(string: "https://huggingface.co/\(validBase)/resolve/main/config.json")!, limit: 1_048_576),
                  let profile = try? AttentionProfile.parseConfig(config, source: "Modello base dichiarato · \(validBase)") {
            model.profile = profile
        }
        try Task.checkCancellation()
        return model
    }

    static func metadata(_ url: URL, limit: Int = 8_388_608) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: HubRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw DeckError.invalidResponse }
        guard response.statusCode == 200 else {
            if response.statusCode == 429 { throw DeckError.rpc("Hugging Face sta limitando le richieste. Attendi e riprova.") }
            if [401, 403].contains(response.statusCode) { throw DeckError.rpc("Repository privato o con accesso riservato. Puoi inserire i dati manualmente.") }
            if response.statusCode == 404 { throw DeckError.rpc("Repository o metadati non trovati su Hugging Face.") }
            throw DeckError.http(response.statusCode)
        }
        guard response.expectedContentLength <= limit else { throw DeckError.rpc("Metadati troppo grandi. Usa i dati manuali.") }
        var data = Data(); data.reserveCapacity(65_536)
        for try await byte in stream {
            data.append(byte)
            if data.count > limit { throw DeckError.rpc("Metadati troppo grandi. Usa i dati manuali.") }
        }
        return data
    }

    public static func parse(_ data: Data, repository: String) throws -> HubModel {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DeckError.invalidResponse }
        let files = root["siblings"] as? [[String: Any]] ?? []
        var singles: [WeightVariant] = [], shards: [String: [(Int, Int, UInt64)]] = [:], tensors: [String: [(String, UInt64)]] = [:]
        let expression = try NSRegularExpression(pattern: "^(.*)-([0-9]{5})-of-([0-9]{5})\\.gguf$", options: .caseInsensitive)
        for item in files {
            guard let name = item["rfilename"] as? String,
                  let size = item["size"] as? NSNumber ?? (item["lfs"] as? [String: Any])?["size"] as? NSNumber,
                  size.doubleValue.isFinite, size.doubleValue > 0, size.doubleValue < Double(Int64.max) else { continue }
            let bytes = size.uint64Value
            let path = name as NSString, lower = name.lowercased()
            if lower.hasSuffix(".gguf"), !path.lastPathComponent.lowercased().contains("mmproj"), !path.lastPathComponent.lowercased().hasPrefix("mtp-"), !lower.contains("-lora.") {
                let range = NSRange(name.startIndex..., in: name)
                if let match = expression.firstMatch(in: name, range: range), let baseRange = Range(match.range(at: 1), in: name), let indexRange = Range(match.range(at: 2), in: name), let countRange = Range(match.range(at: 3), in: name),
                   let index = Int(name[indexRange]), let count = Int(name[countRange]), count > 0, count < 10_000 {
                    shards[String(name[baseRange]), default: []].append((index, count, bytes))
                } else { singles.append(WeightVariant(name: name, bytes: bytes)) }
            } else if lower.hasSuffix(".safetensors"), !path.lastPathComponent.lowercased().hasPrefix("adapter_") {
                tensors[path.deletingLastPathComponent, default: []].append((path.lastPathComponent, bytes))
            }
        }
        for (base, parts) in shards {
            guard let count = parts.first?.1, parts.count == count, parts.allSatisfy({ $0.1 == count }), Set(parts.map(\.0)) == Set(1...count) else { continue }
            singles.append(.init(name: base + ".gguf · \(count) parti", bytes: sum(parts.map(\.2)), files: count))
        }
        for (folder, sizes) in tensors {
            let shardPattern = try NSRegularExpression(pattern: "-([0-9]{5})-of-([0-9]{5})\\.safetensors$", options: .caseInsensitive)
            let indexed: [(Int, Int)] = sizes.compactMap { name, _ in
                guard let match = shardPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                      let a = Range(match.range(at: 1), in: name), let b = Range(match.range(at: 2), in: name),
                      let index = Int(name[a]), let count = Int(name[b]) else { return nil }
                return (index, count)
            }
            if let count = indexed.first?.1 {
                guard count > 0, count < 10_000, indexed.count == count, indexed.allSatisfy({ $0.1 == count }), Set(indexed.map(\.0)) == Set(1...count) else { continue }
            }
            singles.append(.init(name: (folder.isEmpty || folder == "." ? "Safetensors" : folder + " / Safetensors"), bytes: sum(sizes.map(\.1)), files: sizes.count))
        }
        var profile = AttentionProfile()
        let gguf = root["gguf"] as? [String: Any] ?? [:]
        profile.modelType = gguf["architecture"] as? String ?? ""
        profile.layers = gguf["block_count"] as? Int ?? 0
        profile.kvHeads = gguf["attention.head_count_kv"] as? Int ?? 0
        let heads = gguf["attention.head_count"] as? Int ?? 0, hidden = gguf["embedding_length"] as? Int ?? 0
        let dimension = heads > 0 && hidden % heads == 0 ? hidden / heads : 0
        profile.keyDimension = dimension; profile.valueDimension = dimension
        profile.maxContext = gguf["context_length"] as? Int
        profile.source = "Metadati Hugging Face"
        // The optional GGUF summary is not rich enough to rule out hybrid/MLA states.
        if profile.complete { profile.caveat = "Riepilogo GGUF: verifica i parametri di attenzione o carica il config.json del modello base." }
        let card = root["cardData"] as? [String: Any] ?? [:]
        let base = card["base_model"] as? String ?? (card["base_model"] as? [String])?.first
        let parameters = (root["safetensors"] as? [String: Any])?["total"] as? Double ?? gguf["total"] as? Double
        return HubModel(repository: repository, revision: root["sha"] as? String ?? "main", variants: singles.sorted { $0.bytes < $1.bytes }, profile: profile, parameters: parameters, baseModel: base)
    }
    private static func sum(_ sizes: [UInt64]) -> UInt64 {
        sizes.reduce(0) { total, size in let (sum, overflow) = total.addingReportingOverflow(size); return overflow ? UInt64.max : sum }
    }
}
