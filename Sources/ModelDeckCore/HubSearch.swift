import Foundation

public enum HubSearchFormat: String, CaseIterable, Sendable {
    case all, gguf, mlx
    public var title: String { switch self { case .all: "Tutti"; case .gguf: "GGUF"; case .mlx: "MLX" } }
}

public struct HubSearchResult: Identifiable, Sendable {
    public var id: String { repository }
    public let repository: String
    public let downloads: UInt64?
    public let likes: UInt64?
    public let format: String?
    public let task: String?
    public let gated: Bool
    public init(repository: String, downloads: UInt64? = nil, likes: UInt64? = nil, format: String? = nil, task: String? = nil, gated: Bool = false) {
        self.repository = repository; self.downloads = downloads; self.likes = likes; self.format = format; self.task = task; self.gated = gated
    }
}

extension HuggingFaceCatalog {
    public static func searchURL(query: String, format: HubSearchFormat = .all, limit: Int = 20) throws -> URL {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...128).contains(query.count), !query.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DeckError.rpc("Scrivi da 2 a 128 caratteri del nome di un modello.")
        }
        var url = URLComponents(string: "https://huggingface.co/api/models")!
        url.queryItems = [.init(name: "search", value: query), .init(name: "sort", value: "downloads"),
                          .init(name: "direction", value: "-1"), .init(name: "limit", value: String(min(20, max(1, limit)))), .init(name: "full", value: "false")]
        if format != .all { url.queryItems?.append(.init(name: "filter", value: format.rawValue)) }
        guard let result = url.url else { throw DeckError.invalidResponse }
        return result
    }
    public static func search(_ query: String, format: HubSearchFormat = .all) async throws -> [HubSearchResult] {
        let data = try await metadata(searchURL(query: query, format: format), limit: 2_097_152)
        try Task.checkCancellation()
        return try parseSearch(data)
    }
    public static func parseSearch(_ data: Data) throws -> [HubSearchResult] {
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw DeckError.invalidResponse }
        var seen = Set<String>()
        func count(_ value: Any?) -> UInt64? {
            guard let number = value as? NSNumber, number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue < Double(Int64.max) else { return nil }
            return number.uint64Value
        }
        return items.prefix(100).compactMap { item in
            guard item["private"] as? Bool != true, item["disabled"] as? Bool != true,
                  let raw = item["id"] as? String ?? item["modelId"] as? String,
                  let id = try? repositoryID(raw), id == raw, seen.insert(id).inserted else { return nil }
            let tags = item["tags"] as? [String] ?? []
            let library = item["library_name"] as? String
            let format = tags.contains("gguf") || id.lowercased().contains("-gguf") ? "GGUF" : tags.contains("mlx") || library == "mlx" ? "MLX" : library
            let gated = (item["gated"] as? Bool == true) || ["auto", "manual"].contains(item["gated"] as? String ?? "")
            return HubSearchResult(repository: id, downloads: count(item["downloads"]), likes: count(item["likes"]), format: format, task: item["pipeline_tag"] as? String, gated: gated)
        }.prefix(20).map { $0 }
    }
}
