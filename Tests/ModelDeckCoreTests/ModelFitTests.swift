import XCTest
@testable import ModelDeckCore

final class ModelFitTests: XCTestCase {
    private func profile(heads: Int = 32) -> AttentionProfile {
        var profile = AttentionProfile()
        profile.layers = 32; profile.kvHeads = heads
        profile.keyDimension = 128; profile.valueDimension = 128
        return profile
    }
    private func estimate(_ profile: AttentionProfile? = nil, weights: Double = 4, context: Int = 4096, sequences: Int = 1,
                          precision: KVPrecision = .fp16, physical: Double = 16, metal: Double? = 12, assumeStandard: Bool = false) -> FitEstimate {
        MemoryEstimator.estimate(weights: weights * gibibyte, profile: profile ?? self.profile(), context: context, sequences: sequences,
                                 precision: precision, physicalMemory: physical * gibibyte, metalLimit: metal.map { $0 * gibibyte },
                                 reserve: 4 * gibibyte, assumeStandard: assumeStandard)
    }
    func testKVCacheUsesKVHeadsAndScalesWithContextAndSequences() throws {
        XCTAssertEqual(try XCTUnwrap(estimate().kvCache) / gibibyte, 2, accuracy: 0.00001)
        let gqa = profile(heads: 8)
        XCTAssertEqual(try XCTUnwrap(estimate(gqa).kvCache) / gibibyte, 0.5, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(estimate(gqa, context: 8192, sequences: 3).kvCache) / gibibyte, 3, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(estimate(gqa, precision: .q8).kvCache) / gibibyte, 0.5 * 34 / 64, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(estimate(gqa, precision: .q4).kvCache) / gibibyte, 0.5 * 18 / 64, accuracy: 0.00001)
    }
    func testVerdictsIncludeRuntimeReserveAndMetalBudget() {
        XCTAssertEqual(estimate().verdict, .fits)
        XCTAssertEqual(estimate(weights: 8).verdict, .tight)
        XCTAssertEqual(estimate(weights: 10).verdict, .tooLarge)
        XCTAssertEqual(estimate(metal: 6).budget / gibibyte, 6)
        XCTAssertEqual(estimate(metal: 20).budget / gibibyte, 12)
        XCTAssertEqual(estimate(metal: nil).budget / gibibyte, 12)
        XCTAssertEqual(estimate(weights: 40).verdict, .tooLarge)
    }
    func testMissingMetadataInvalidInputsAndUnsupportedContextNeverGreen() {
        XCTAssertEqual(estimate(AttentionProfile()).verdict, .incomplete)
        XCTAssertNil(estimate(AttentionProfile()).kvCache)
        XCTAssertEqual(estimate(weights: 0).verdict, .incomplete)
        XCTAssertEqual(estimate(weights: .nan).verdict, .incomplete)
        XCTAssertEqual(estimate(context: -1).verdict, .incomplete)
        XCTAssertEqual(estimate(sequences: 0).verdict, .incomplete)
        var limited = profile(); limited.maxContext = 2048
        XCTAssertEqual(estimate(limited).verdict, .incomplete)
        limited.caveat = "Unsupported state"
        limited.maxContext = 8192
        XCTAssertEqual(estimate(limited).verdict, .incomplete)
        XCTAssertEqual(estimate(limited, assumeStandard: true).verdict, .fits)
    }
    func testConfigGQAAndSpecialArchitectures() throws {
        let base: [String: Any] = ["model_type": "qwen2", "num_hidden_layers": 36, "num_attention_heads": 16,
                                   "num_key_value_heads": 2, "hidden_size": 2048, "max_position_embeddings": 32768]
        func parse(_ changes: [String: Any] = [:]) throws -> AttentionProfile {
            try AttentionProfile.parseConfig(JSONSerialization.data(withJSONObject: base.merging(changes, uniquingKeysWith: { _, new in new })))
        }
        let gqa = try parse()
        XCTAssertTrue(gqa.complete); XCTAssertNil(gqa.caveat)
        XCTAssertEqual(gqa.layers, 36); XCTAssertEqual(gqa.kvHeads, 2); XCTAssertEqual(gqa.keyDimension, 128)
        XCTAssertEqual(gqa.maxContext, 32768)
        for changes: [String: Any] in [["kv_lora_rank": 512], ["model_type": "qwen3_5"], ["model_type": "unrecognized"], ["vision_config": [:]]] {
            let special = try parse(changes)
            XCTAssertNotNil(special.caveat)
            XCTAssertEqual(estimate(special).verdict, .incomplete)
        }
        let hybrid = try parse(["layer_types": ["full_attention", "linear_attention", "full_attention"]])
        XCTAssertEqual(hybrid.layers, 2); XCTAssertNotNil(hybrid.caveat)
        let nested = try AttentionProfile.parseConfig(JSONSerialization.data(withJSONObject: ["text_config": base, "vision_config": [:]]))
        XCTAssertTrue(nested.complete); XCTAssertNotNil(nested.caveat)
    }
    func testRepositoryInputOnlyAcceptsPublicHubRepositoryShape() throws {
        XCTAssertEqual(try HuggingFaceCatalog.repositoryID(" Qwen/Qwen2.5-3B-Instruct "), "Qwen/Qwen2.5-3B-Instruct")
        XCTAssertEqual(try HuggingFaceCatalog.repositoryID("https://huggingface.co/Qwen/Test/"), "Qwen/Test")
        for invalid in ["../model", "a/..", "a/b/c", "a//b", "http://huggingface.co/a/b", "https://other.example/a/b",
                        "https://user:pass@huggingface.co/a/b", "https://huggingface.co:443/a/b", "a/b?token=secret"] {
            XCTAssertThrowsError(try HuggingFaceCatalog.repositoryID(invalid), invalid)
        }
    }
    func testHubGroupsCompleteWeightShardsAndExcludesAdapters() throws {
        let files: [(String, Int)] = [("q4-00001-of-00002.gguf", 100), ("q4-00002-of-00002.gguf", 120),
                                     ("q8-00001-of-00002.gguf", 200), ("single.gguf", 80), ("mmproj.gguf", 40),
                                     ("full/model-00001-of-00002.safetensors", 500), ("full/model-00002-of-00002.safetensors", 600),
                                     ("partial/model-00001-of-00002.safetensors", 300), ("adapter_model.safetensors", 20)]
        let data = try JSONSerialization.data(withJSONObject: ["siblings": files.map { ["rfilename": $0.0, "size": $0.1] as [String: Any] }])
        let model = try HuggingFaceCatalog.parse(data, repository: "test/model")
        XCTAssertEqual(model.variants.map(\.bytes), [80, 220, 1100])
        XCTAssertEqual(model.variants.map(\.files), [1, 2, 2])
        XCTAssertFalse(model.profile.complete)
    }
    func testLocalSplitWeightsAreGroupedAndIncompleteDownloadsExcluded() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
        for (name, size) in [("q4-00001-of-00002.gguf", 10), ("q4-00002-of-00002.gguf", 20),
                             ("q8-00001-of-00002.gguf", 25), ("model-00001-of-00002.safetensors", 50), ("adapter_model.safetensors", 5)] {
            try Data(repeating: 0, count: size).write(to: folder.appendingPathComponent(name))
        }
        let models = ModelInventory.scanFolder(folder, source: .folder)
        XCTAssertEqual(models.count, 1); XCTAssertEqual(models.first?.bytes, 30)
        XCTAssertEqual(models.first?.path?.lastPathComponent, "q4-00001-of-00002.gguf")
    }
    func testGGUFReaderSkipsSmallArraysAndDoesNotReadTokenizerData() throws {
        var data = Data("GGUF".utf8)
        func integer(_ value: UInt64, _ size: Int) { for i in 0..<size { data.append(UInt8(truncatingIfNeeded: value >> (8 * i))) } }
        func string(_ value: String) { integer(UInt64(value.utf8.count), 8); data.append(Data(value.utf8)) }
        func scalar(_ key: String, _ value: UInt64) { string(key); integer(4, 4); integer(value, 4) }
        integer(3, 4); integer(0, 8); integer(8, 8)
        string("general.tags"); integer(9, 4); integer(8, 4); integer(2, 8); string("a"); string("b")
        string("general.architecture"); integer(8, 4); string("llama")
        scalar("llama.block_count", 32); scalar("llama.attention.head_count", 32)
        scalar("llama.attention.head_count_kv", 8); scalar("llama.embedding_length", 4096)
        scalar("llama.context_length", 8192)
        // Deliberately absent giant array body: the parser must stop at this key.
        string("tokenizer.ggml.tokens"); integer(9, 4)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)
        let profile = try GGUFProfile.read(file)
        XCTAssertTrue(profile.complete); XCTAssertNil(profile.caveat)
        XCTAssertEqual(profile.layers, 32); XCTAssertEqual(profile.kvHeads, 8); XCTAssertEqual(profile.valueDimension, 128)
        XCTAssertEqual(profile.maxContext, 8192)
        try Data("GGUF".utf8).write(to: file)
        XCTAssertThrowsError(try GGUFProfile.read(file))
    }
    func testOllamaShowMetadataUsesArchitectureAndFlagsVision() throws {
        let info: [String: Any] = ["general.architecture": "qwen2", "qwen2.block_count": 36,
                                   "qwen2.attention.head_count": 16, "qwen2.attention.head_count_kv": 2, "qwen2.embedding_length": 2048]
        let text = try LocalFitMetadata.parseOllama(JSONSerialization.data(withJSONObject: ["model_info": info]))
        XCTAssertTrue(text.complete); XCTAssertNil(text.caveat); XCTAssertEqual(text.keyDimension, 128)
        let vision = try LocalFitMetadata.parseOllama(JSONSerialization.data(withJSONObject: ["model_info": info, "capabilities": ["vision"]]))
        XCTAssertEqual(estimate(vision).verdict, .incomplete)
    }
}
