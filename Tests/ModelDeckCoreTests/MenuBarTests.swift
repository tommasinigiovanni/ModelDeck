import XCTest
@testable import ModelDeckCore

final class MenuBarTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func usage() -> SubscriptionUsage {
        SubscriptionUsage(provider: "Claude", windows: [
            .init(id: "five_hour", title: "5 ore", usedPercent: 0, resetsAt: now.addingTimeInterval(100), durationMinutes: 300),
            .init(id: "seven_day", title: "7 giorni", usedPercent: 74, resetsAt: now.addingTimeInterval(1000), durationMinutes: 10080)
        ], updatedAt: now, source: "Fixture")
    }
    private func render(_ options: MenuBarOptions, claude: SubscriptionUsage? = nil, codex: SubscriptionUsage? = nil, snapshot: SystemSnapshot = .init()) -> MenuBarSummary {
        .render(options: options, snapshot: snapshot, claude: claude ?? usage(), openAI: codex ?? .init(provider: "OpenAI", source: "Fixture"), now: now)
    }
    func testZeroQuotaIsValidAndMissingOrExpiredWindowsNeverBecomeZero() {
        var options = MenuBarOptions(); options.metrics = [.claude, .openAI]
        let valid = render(options)
        XCTAssertEqual(valid.title, "CL5h 0%   OA —")
        var expired = usage(); expired.windows[0].resetsAt = now.addingTimeInterval(-1)
        XCTAssertTrue(render(options, claude: expired).title.hasPrefix("CL5h —"))
        options.claudeWindowID = "removed-window"
        XCTAssertTrue(render(options).title.hasPrefix("CL —"))
        XCTAssertFalse(render(options).title.contains("74%"))
    }
    func testSelectedWeeklyRemainingQuotaAndOverage() {
        var options = MenuBarOptions(); options.metrics = [.claude]; options.quotaStyle = .remaining; options.claudeWindowID = "seven_day"
        XCTAssertEqual(render(options).title, "CL7g 26%")
        XCTAssertTrue(render(options).tooltip.contains("26% rimanente"))
        var overage = usage(); overage.windows[1].usedPercent = 120
        XCTAssertEqual(render(options, claude: overage).title, "CL7g 0%")
    }
    func testStaleValuesAndRefreshErrorsAreMarkedAndInvalidNumbersAreUnavailable() {
        var options = MenuBarOptions(); options.metrics = [.claude]
        var stale = usage(); stale.updatedAt = now.addingTimeInterval(-601)
        XCTAssertEqual(render(options, claude: stale).title, "CL5h 0%*")
        XCTAssertTrue(render(options, claude: stale).tooltip.contains("da aggiornare"))
        var failed = usage(); failed.message = "Connection failed"
        XCTAssertEqual(render(options, claude: failed).title, "CL5h 0%*")
        failed.windows[0].usedPercent = .nan
        XCTAssertEqual(render(options, claude: failed).title, "CL5h —")
    }
    func testCodexDefaultPrefersMainBucketAndExplicitSelectionIsRespected() throws {
        let data = Data(#"{"rateLimitsByLimitId":{"a-review":{"primary":{"usedPercent":91,"windowDurationMins":60}},"codex":{"primary":{"usedPercent":12,"windowDurationMins":300},"secondary":{"usedPercent":55,"windowDurationMins":10080}}}}"#.utf8)
        let codex = try CodexUsage.parse(data, now: now)
        var options = MenuBarOptions(); options.metrics = [.openAI]
        XCTAssertEqual(render(options, codex: codex).title, "OA5h 12%")
        options.openAIWindowID = "codex-secondary"
        XCTAssertEqual(render(options, codex: codex).title, "OA7g 55%")
        options.openAIWindowID = "a-review-primary"
        XCTAssertEqual(render(options, codex: codex).title, "OA1h 91%")
        XCTAssertTrue(render(options, codex: codex).tooltip.contains("a-review"))
    }
    func testMetricSelectionMemoryUnitsAndUnavailableSamples() {
        var options = MenuBarOptions(); options.metrics = [.cpu, .memory, .gpu]
        XCTAssertEqual(render(options).title, "CPU —   RAM —   GPU —")
        var snapshot = SystemSnapshot(); snapshot.cpu = 0; snapshot.gpu = 16; snapshot.memoryTotal = 16_000_000_000; snapshot.memoryUsed = 8_000_000_000
        XCTAssertEqual(render(options, snapshot: snapshot).title, "CPU 0%   RAM 50%   GPU 16%")
        options.metrics = [.memory]; options.memoryStyle = .used
        XCTAssertEqual(render(options, snapshot: snapshot).title, "RAM " + DeckFormat.bytes(snapshot.memoryUsed))
        options.metrics = []
        XCTAssertEqual(render(options).title, "")
    }
}
