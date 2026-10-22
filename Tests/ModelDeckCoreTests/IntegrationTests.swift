import XCTest
import SQLite3
@testable import ModelDeckCore

final class IntegrationTests: XCTestCase {
    func testUnslothReadsOnlyModelDirectoryPreferencesWithoutWriting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("studio.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        let sql = """
        CREATE TABLE app_settings (key TEXT PRIMARY KEY, value_json TEXT);
        INSERT INTO app_settings VALUES ('hugging_face_cache_home', '"/Volumes/Models/HF"');
        INSERT INTO app_settings VALUES ('hugging_face_download_homes', '["/Volumes/Downloads"]');
        INSERT INTO app_settings VALUES ('unrelated_setting', '"/private/not-models"');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let original = try Data(contentsOf: database)
        XCTAssertEqual(ModelInventory.unslothModelDirectories(database: database), ["/Volumes/Downloads", "/Volumes/Models/HF"])
        XCTAssertEqual(try Data(contentsOf: database), original)
        let missing = directory.appendingPathComponent("missing.db")
        XCTAssertEqual(ModelInventory.unslothModelDirectories(database: missing), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
    func testUnslothDoesNotAssumeListedModelsAreLoaded() throws {
        let catalog = Data(#"{"data":[{"id":"unsloth/Qwen","loaded":false},{"id":"other","size_bytes":42}]}"#.utf8)
        let models = try ModelInventory.parseUnsloth(catalog, running: nil)
        XCTAssertEqual(models[0].source, .unsloth)
        XCTAssertEqual(models[0].loaded, false); XCTAssertNil(models[1].loaded)
        let live = Data(#"{"data":[{"id":"other","loaded":true}]}"#.utf8)
        XCTAssertEqual(try ModelInventory.parseUnsloth(catalog, running: live)[1].loaded, true)
    }
    func testHuggingFaceSymlinksAndSelectedRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("models--unsloth--Test")
        let snapshot = repo.appendingPathComponent("snapshots/abc123")
        let old = repo.appendingPathComponent("snapshots/old")
        let blob = repo.appendingPathComponent("blobs/weights")
        for directory in [snapshot, old, blob.deletingLastPathComponent(), repo.appendingPathComponent("refs")] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data("abc123".utf8).write(to: repo.appendingPathComponent("refs/main"))
        try Data(repeating: 0, count: 128).write(to: blob)
        try FileManager.default.createSymbolicLink(at: snapshot.appendingPathComponent("model.gguf"), withDestinationURL: blob)
        try Data(repeating: 0, count: 16).write(to: old.appendingPathComponent("old.gguf"))
        let models = ModelInventory.scanHuggingFace(root)
        XCTAssertEqual(models.count, 1); XCTAssertEqual(models.first?.bytes, 128)
        XCTAssertTrue(models.first?.name.contains("unsloth/Test") == true)
    }
    func testCodexRPCReadsSmallResponsesWithoutWaitingForEOF() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("mock-codex")
        let script = """
        #!/bin/sh
        read -r initialize
        printf '%s\\n' '{"id":0,"result":{}}'
        read -r initialized
        read -r request
        printf '%s\\n' '{"id":1,"result":{"rateLimits":{"primary":{"usedPercent":17,"windowDurationMins":300}}}}'
        read -r finished
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let start = Date()
        let usage = try await CodexUsage.read(executableURL: executable)
        XCTAssertEqual(usage.windows.first?.usedPercent, 17)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
    func testOllamaSeparatesUnknownFromUnloaded() throws {
        let tags = Data(#"{"models":[{"name":"llama:latest","size":500,"details":{"format":"gguf","quantization_level":"Q4_K_M"}}]}"#.utf8)
        XCTAssertNil(try ModelInventory.parseOllama(tags: tags, running: nil).first?.loaded)
        XCTAssertEqual(try ModelInventory.parseOllama(tags: tags, running: Data(#"{"models":[]}"#.utf8)).first?.loaded, false)
        let live = Data(#"{"models":[{"name":"llama:latest","size_vram":400,"context_length":8192}]}"#.utf8)
        let model = try XCTUnwrap(ModelInventory.parseOllama(tags: tags, running: live).first)
        XCTAssertEqual(model.loaded, true); XCTAssertEqual(model.vram, 400); XCTAssertEqual(model.context, 8192)
    }
    func testLMStudioV1AndV0() throws {
        let v1 = Data(#"{"models":[{"key":"qwen","display_name":"Qwen","size_bytes":120,"format":"mlx","quantization":{"name":"4bit"},"loaded_instances":[{"id":"a"}]}]}"#.utf8)
        let model = try XCTUnwrap(ModelInventory.parseLMStudio(v1).first)
        XCTAssertEqual(model.name, "Qwen"); XCTAssertEqual(model.loaded, true); XCTAssertEqual(model.quantization, "4bit")
        let v0 = Data(#"{"data":[{"id":"qwen","compatibility_type":"gguf","quantization":"Q6_K","state":"not-loaded"}]}"#.utf8)
        XCTAssertEqual(try ModelInventory.parseLMStudio(v0).first?.loaded, false)
    }
    func testSafetensorsShardsAreOneModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))
        try Data(repeating: 0, count: 10).write(to: root.appendingPathComponent("model-00001.safetensors"))
        try Data(repeating: 0, count: 20).write(to: root.appendingPathComponent("model-00002.safetensors"))
        try Data(repeating: 0, count: 4).write(to: root.appendingPathComponent("mmproj-test.gguf"))
        let models = ModelInventory.scanFolder(root, source: .folder)
        XCTAssertEqual(models.count, 1); XCTAssertEqual(models.first?.bytes, 30)
    }
    func testClaudeBridgeRestoresOriginalAndPreservesOtherSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings = root.appendingPathComponent("settings.json"), state = root.appendingPathComponent("backup.json")
        try Data(#"{"theme":"dark","statusLine":{"type":"command","command":"printf 'old status'","padding":2}}"#.utf8).write(to: settings)
        try ClaudeBridge.install(executable: URL(fileURLWithPath: "/Applications/Test App's.app/ModelDeck"), settings: settings, state: state)
        XCTAssertTrue(ClaudeBridge.isInstalled(settings: settings, state: state))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertEqual(json["theme"] as? String, "dark")
        XCTAssertEqual((json["statusLine"] as? [String: Any])?["padding"] as? Int, 2)
        json["theme"] = "light"
        try JSONSerialization.data(withJSONObject: json).write(to: settings)
        try ClaudeBridge.uninstall(settings: settings, state: state)
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertEqual(restored["theme"] as? String, "light")
        XCTAssertEqual((restored["statusLine"] as? [String: Any])?["command"] as? String, "printf 'old status'")
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
    }
    func testClaudeBridgeRefusesToOverwriteLaterChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json"), state = root.appendingPathComponent("backup.json")
        try ClaudeBridge.install(executable: URL(fileURLWithPath: "/tmp/ModelDeck"), settings: settings, state: state)
        let changed = Data(#"{"statusLine":{"type":"command","command":"new command"}}"#.utf8)
        try changed.write(to: settings)
        XCTAssertThrowsError(try ClaudeBridge.uninstall(settings: settings, state: state))
        XCTAssertEqual(try Data(contentsOf: settings), changed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path))
    }
}
