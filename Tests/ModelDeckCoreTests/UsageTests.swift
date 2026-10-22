import XCTest
@testable import ModelDeckCore

final class UsageTests: XCTestCase {
    func testCodexIncludesAllBucketsAndZeroUsage() throws {
        let data = Data(#"{"rateLimitsByLimitId":{"codex":{"planType":"pro","primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":2000000000},"secondary":{"usedPercent":58,"windowDurationMins":10080}},"review":{"primary":{"usedPercent":12,"windowDurationMins":60}}}}"#.utf8)
        let usage = try CodexUsage.parse(data)
        XCTAssertEqual(usage.windows.count, 3)
        XCTAssertEqual(usage.windows.first?.usedPercent, 0)
        XCTAssertEqual(usage.plan, "pro")
        XCTAssertTrue(usage.windows.contains { $0.title.contains("7 giorni") })
    }
    func testUnavailableCodexIsNotZeroPercent() throws {
        let usage = try CodexUsage.parse(Data(#"{"rateLimits":null}"#.utf8))
        XCTAssertTrue(usage.windows.isEmpty)
        XCTAssertNotNil(usage.message)
    }
    func testLegacyCodexWindow() throws {
        let usage = try CodexUsage.parse(Data(#"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":15,"resetsAt":2000000000}}}"#.utf8))
        XCTAssertEqual(usage.windows.first?.title, "15 min")
        XCTAssertEqual(usage.windows.first?.resetsAt, Date(timeIntervalSince1970: 2000000000))
    }
    func testClaudeCapturePersistsOnlyQuotasAndDoesNotEraseOnEmptyEvent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.json")
        let input = Data(#"{"transcript_path":"sensitive","session_id":"private","rate_limits":{"five_hour":{"used_percentage":0,"resets_at":2000000000,"secret":"omit"}},"model":{"display_name":"test"}}"#.utf8)
        try ClaudeUsage.capture(input, to: url, now: Date(timeIntervalSince1970: 1000))
        let original = try Data(contentsOf: url)
        let text = String(decoding: original, as: UTF8.self)
        XCTAssertFalse(text.contains("sensitive")); XCTAssertFalse(text.contains("secret")); XCTAssertFalse(text.contains("private"))
        let usage = try ClaudeUsage.parse(original)
        XCTAssertEqual(usage.windows.first?.usedPercent, 0)
        XCTAssertEqual(usage.updatedAt, Date(timeIntervalSince1970: 1000))
        try ClaudeUsage.capture(Data("{}".utf8), to: url)
        XCTAssertEqual(original, try Data(contentsOf: url))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testExpiredQuotaIsMarkedExpired() throws {
        let usage = try ClaudeUsage.parse(Data(#"{"updated_at":1000,"rate_limits":{"seven_day":{"used_percentage":78,"resets_at":100}}}"#.utf8))
        XCTAssertTrue(usage.windows[0].isExpired)
        XCTAssertTrue(usage.stale)
    }
    func testLoopbackOnlyEndpoints() throws {
        XCTAssertNoThrow(try LocalHTTP.endpoint("http://127.0.0.1:11434"))
        XCTAssertNoThrow(try LocalHTTP.endpoint("http://[::1]:11434"))
        for endpoint in ["https://example.com", "http://localhost.evil.test", "file:///tmp/models", "http://user:password@localhost", "http://127.0.0.1?token=test"] {
            XCTAssertThrowsError(try LocalHTTP.endpoint(endpoint))
        }
    }
}
