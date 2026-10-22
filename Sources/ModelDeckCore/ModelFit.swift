import Foundation

public let gibibyte = 1_073_741_824.0

public struct AttentionProfile: Sendable {
    public var modelType = ""
    public var layers = 0
    public var kvHeads = 0
    public var keyDimension = 0
    public var valueDimension = 0
    public var maxContext: Int?
    public var caveat: String?
    public var source = "Dati manuali"
    public init() {}
    public var complete: Bool { layers > 0 && layers <= 512 && kvHeads > 0 && kvHeads <= 2048 && keyDimension > 0 && keyDimension <= 16384 && valueDimension > 0 && valueDimension <= 16384 }

    public static func parseConfig(_ data: Data, source: String = "config.json") throws -> AttentionProfile {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DeckError.invalidResponse }
        let config = root["text_config"] as? [String: Any] ?? root
        var result = AttentionProfile(); result.source = source
        result.modelType = config["model_type"] as? String ?? root["model_type"] as? String ?? ""
        result.layers = config["num_hidden_layers"] as? Int ?? config["n_layer"] as? Int ?? 0
        let heads = config["num_attention_heads"] as? Int ?? config["n_head"] as? Int ?? 0
        result.kvHeads = config["num_key_value_heads"] as? Int ?? heads
        let hidden = config["hidden_size"] as? Int ?? config["n_embd"] as? Int ?? 0
        let dimension = config["head_dim"] as? Int ?? (heads > 0 && hidden % heads == 0 ? hidden / heads : 0)
        result.keyDimension = dimension; result.valueDimension = dimension
        result.maxContext = config["max_position_embeddings"] as? Int
        let standard = ["llama", "qwen2", "qwen3", "qwen2_moe", "qwen3_moe", "mistral", "mixtral", "gemma", "gemma2", "gemma3_text", "phi", "phi3", "gpt2", "gpt_neox", "starcoder2", "olmo", "olmo2", "cohere", "cohere2", "internlm2"]
        if !standard.contains(result.modelType) { result.caveat = "Architettura non riconosciuta: verifica che i parametri descrivano una cache KV standard." }
        let types = config["layer_types"] as? [String] ?? []
        let hybrid = types.contains { $0.contains("linear") || $0.contains("mamba") || $0.contains("ssm") }
        if hybrid {
            result.layers = types.filter { $0.contains("attention") && !$0.contains("linear") }.count
            result.caveat = "Architettura ibrida: stato ricorrente e buffer specifici non sono inclusi nella cache KV standard."
        }
        if config["kv_lora_rank"] != nil { result.caveat = "Attenzione MLA: la formula KV standard non descrive questa architettura." }
        if config["linear_num_key_heads"] != nil || config["ssm_cfg"] != nil || result.modelType.contains("qwen3_5") || result.modelType.contains("qwen3_8") {
            result.caveat = "Architettura ibrida: stato ricorrente e buffer specifici richiedono una stima del runtime."
        }
        if root["vision_config"] != nil || root["audio_config"] != nil { result.caveat = "Modello multimodale: encoder, immagini/audio e relativi buffer richiedono memoria aggiuntiva." }
        if result.modelType.lowercased().contains("mamba") { result.caveat = "Modello a stato ricorrente: serve una stima specifica del runtime." }
        return result
    }
}

public enum KVPrecision: String, CaseIterable, Sendable {
    case fp16 = "FP16 / BF16", q8 = "Q8_0 · llama.cpp", q4 = "Q4_0 · llama.cpp"
    public var bytesPerValue: Double { switch self { case .fp16: 2; case .q8: 34.0 / 32.0; case .q4: 18.0 / 32.0 } }
}

public enum FitVerdict: String, Sendable {
    case fits = "Rientra nel budget", tight = "Vicino al limite", tooLarge = "Supera il budget di memoria", incomplete = "Servono altri dati"
}

public struct FitEstimate: Sendable {
    public let weights: Double
    public let kvCache: Double?
    public let runtime: Double
    public let budget: Double
    public let total: Double?
    public let minimum: Double
    public let verdict: FitVerdict
    public let note: String
}

public enum MemoryEstimator {
    public static func estimate(weights: Double, profile: AttentionProfile, context: Int, sequences: Int = 1, precision: KVPrecision = .fp16,
                                physicalMemory: Double, metalLimit: Double? = nil, reserve: Double = 4 * gibibyte,
                                runtimeFraction: Double = 0.15, extra: Double = 0, assumeStandard: Bool = false) -> FitEstimate {
        let validWeights = weights.isFinite && weights > 0
        let validSettings = context > 0 && context <= 10_000_000 && sequences > 0 && sequences <= 64 && reserve.isFinite && reserve >= 0 && runtimeFraction.isFinite && runtimeFraction >= 0 && extra.isFinite && extra >= 0
        let budget = max(0, min(max(0, physicalMemory - max(0, reserve)), metalLimit ?? physicalMemory))
        let safeWeights = validWeights ? weights : 0
        let runtime = max(gibibyte, safeWeights * (runtimeFraction.isFinite ? max(0, runtimeFraction) : 0.15)) + (extra.isFinite ? max(0, extra) : 0)
        var kv: Double?
        if profile.complete && validSettings {
            kv = Double(profile.layers) * Double(profile.kvHeads) * Double(profile.keyDimension + profile.valueDimension) * Double(context) * Double(sequences) * precision.bytesPerValue
        }
        let minimum = safeWeights + runtime
        let total = kv.map { minimum + $0 }
        let validContext = profile.maxContext.map { $0 <= 0 || context <= $0 } ?? true
        let complete = validWeights && validSettings && validContext && profile.complete && (profile.caveat == nil || assumeStandard)
        let verdict: FitVerdict
        let note: String
        if !validSettings {
            verdict = .incomplete; note = "Controlla contesto, sequenze e margini: servono valori numerici validi e non negativi."
        } else if validWeights && minimum > budget {
            verdict = .tooLarge; note = "Pesi e margine di inferenza superano già il budget, prima della cache KV."
        } else if !complete {
            verdict = .incomplete; note = !validContext ? "Il contesto richiesto supera quello dichiarato nei metadati del modello." : profile.caveat ?? "Inserisci dimensione dei pesi e parametri dell’attenzione per stimare anche la cache KV."
        } else if let total, total > budget {
            verdict = .tooLarge; note = "Prova un contesto più corto o una quantizzazione dei pesi/cache supportata dal runtime."
        } else if let total, total > budget * 0.85 {
            verdict = .tight; note = "Il margine è ridotto. Altre app, prefill e buffer del runtime possono causare swap o errori di memoria."
        } else {
            verdict = .fits; note = "La memoria stimata rientra nel budget. Formato, backend e velocità vanno verificati nel runtime scelto."
        }
        return FitEstimate(weights: safeWeights, kvCache: kv, runtime: runtime, budget: budget, total: total, minimum: minimum, verdict: verdict, note: note)
    }
    public static func gib(_ bytes: Double) -> String { bytes.isFinite ? String(format: "%.2f GiB", bytes / gibibyte) : "—" }
}

public enum LocalFitMetadata {
    public static func ollama(model: String, endpoint: String) async throws -> AttentionProfile {
        let base = try LocalHTTP.endpoint(endpoint)
        return try parseOllama(await LocalHTTP.modelDetails(base, name: model))
    }
    public static func parseOllama(_ data: Data) throws -> AttentionProfile {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let metadata = root["model_info"] as? [String: Any],
              let architecture = metadata["general.architecture"] as? String else { throw DeckError.invalidResponse }
        let values = metadata.reduce(into: [String: UInt64]()) { result, pair in
            if let number = pair.value as? NSNumber, number.doubleValue >= 0, number.doubleValue < Double(Int64.max) { result[pair.key] = number.uint64Value }
        }
        var profile = GGUFProfile.profile(architecture, values); profile.source = "Ollama · metadati locali"
        let capabilities = root["capabilities"] as? [String] ?? []
        if capabilities.contains("vision") { profile.caveat = "Modello multimodale: encoder e buffer delle immagini richiedono memoria aggiuntiva." }
        return profile
    }
    public static func read(_ model: LocalModel) -> AttentionProfile {
        guard let path = model.path else { return AttentionProfile() }
        if path.pathExtension.lowercased() == "gguf", let profile = try? GGUFProfile.read(path) { return profile }
        let folder = path.hasDirectoryPath ? path : path.deletingLastPathComponent()
        if let file = try? FileHandle(forReadingFrom: folder.appendingPathComponent("config.json")) {
            defer { try? file.close() }
            if let data = try? file.read(upToCount: 1_048_577), data.count <= 1_048_576,
           let profile = try? AttentionProfile.parseConfig(data, source: "config.json locale") { return profile }
        }
        return AttentionProfile()
    }
}

/// Bounded metadata reader: never reads model tensors or tokenizer arrays.
public enum GGUFProfile {
    public static func read(_ url: URL) throws -> AttentionProfile {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd(); try handle.seek(toOffset: 0)
        var consumed = 0
        func bytes(_ count: Int) throws -> Data {
            consumed += count
            guard count >= 0, consumed <= 4_194_304, let data = try handle.read(upToCount: count), data.count == count else { throw DeckError.invalidResponse }
            return data
        }
        func integer(_ count: Int) throws -> UInt64 {
            let data = try bytes(count)
            return data.enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
        }
        func string() throws -> String {
            let size = try integer(8)
            guard size <= 65_536 else { throw DeckError.invalidResponse }
            return String(decoding: try bytes(Int(size)), as: UTF8.self)
        }
        func skip(_ type: UInt64, depth: Int = 0) throws {
            guard depth < 3 else { throw DeckError.invalidResponse }
            switch type {
            case 0, 1, 7: _ = try bytes(1)
            case 2, 3: _ = try bytes(2)
            case 4, 5, 6: _ = try bytes(4)
            case 10, 11, 12: _ = try bytes(8)
            case 8: _ = try string()
            case 9:
                let element = try integer(4), count = try integer(8)
                guard count <= 10_000 else { throw DeckError.invalidResponse }
                for _ in 0..<count { try skip(element, depth: depth + 1) }
            default: throw DeckError.invalidResponse
            }
        }
        guard try bytes(4) == Data("GGUF".utf8) else { throw DeckError.invalidResponse }
        let version = try integer(4)
        guard version == 2 || version == 3 else { throw DeckError.invalidResponse }
        _ = try integer(8)
        let entries = try integer(8)
        guard entries < 100_000, length >= 24 else { throw DeckError.invalidResponse }
        var values: [String: UInt64] = [:], architecture = ""
        for _ in 0..<entries {
            let key = try string(), type = try integer(4)
            if key.hasPrefix("tokenizer.") { break }
            switch type {
            case 0, 1, 7: values[key] = try integer(1)
            case 2, 3: values[key] = try integer(2)
            case 4, 5: values[key] = try integer(4)
            case 6: _ = try bytes(4)
            case 8:
                let value = try string()
                if key == "general.architecture" { architecture = value }
            case 10, 11: values[key] = try integer(8)
            case 12: _ = try bytes(8)
            case 9:
                do { try skip(9) } catch { return profile(architecture, values) }
            default: // Arrays or unfamiliar types: return the scalar metadata already collected.
                return profile(architecture, values)
            }
        }
        return profile(architecture, values)
    }
    static func profile(_ architecture: String, _ values: [String: UInt64]) -> AttentionProfile {
        func value(_ suffix: String) -> Int { Int(clamping: values[architecture + "." + suffix] ?? 0) }
        var result = AttentionProfile(); result.source = "Metadati GGUF locali"; result.modelType = architecture
        result.layers = value("block_count"); result.kvHeads = value("attention.head_count_kv")
        let heads = value("attention.head_count"), hidden = value("embedding_length")
        if result.kvHeads == 0 { result.kvHeads = heads }
        let dimension = heads > 0 && hidden % heads == 0 ? hidden / heads : 0
        result.keyDimension = value("attention.key_length"); if result.keyDimension == 0 { result.keyDimension = dimension }
        result.valueDimension = value("attention.value_length"); if result.valueDimension == 0 { result.valueDimension = dimension }
        let context = value("context_length"); result.maxContext = context > 0 ? context : nil
        let standard = ["llama", "qwen2", "qwen2moe", "qwen3", "qwen3moe", "mistral", "gemma", "gemma2", "gemma3", "phi2", "phi3", "gpt2", "gptneox", "starcoder2", "olmo", "olmo2", "cohere2", "internlm2"]
        if !standard.contains(architecture) { result.caveat = "Architettura GGUF non riconosciuta: verifica il comportamento della cache nel runtime." }
        if values.keys.contains(where: { $0.contains("ssm.") }) || architecture.replacingOccurrences(of: "_", with: "").contains("qwen35") || architecture.contains("mamba") || architecture.contains("deepseek2") {
            result.caveat = "Architettura ibrida, ricorrente o MLA: la cache standard è solo un’approssimazione parziale."
        }
        if values.keys.contains(where: { $0.contains(".vision.") || $0.contains(".audio.") }) { result.caveat = "Modello multimodale: memoria aggiuntiva di encoder e input non inclusa." }
        return result
    }
}
