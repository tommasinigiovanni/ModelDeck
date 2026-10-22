import XCTest
import Darwin
@testable import ModelDeckCore

final class ProcessTests: XCTestCase {
    func testCPUUsesNanosecondDeltasAndAllowsMultipleCores() {
        XCTAssertEqual(ProcessMonitor.percent(current: 5_000_000_000, previous: 1_000_000_000, elapsed: 2), 200)
        XCTAssertNil(ProcessMonitor.percent(current: 1, previous: nil, elapsed: 2))
        XCTAssertNil(ProcessMonitor.percent(current: 1, previous: 2, elapsed: 2))
        XCTAssertNil(ProcessMonitor.percent(current: 1, previous: 0, elapsed: 0))
    }
    func testTerminationRejectsChangedIdentityAndStopsOnlyOwnedTestChild() async throws {
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let monitor = ProcessMonitor()
        let processes = await monitor.sample()
        let actual = try XCTUnwrap(processes.first { $0.pid == child.processIdentifier })
        let wrong = RunningProcess(id: .init(pid: actual.pid, startedSeconds: 0, startedMicroseconds: 0), name: actual.name, path: actual.path, userID: actual.userID, cpu: nil, memory: nil, gpu: nil, gpuClient: false, threads: nil)
        XCTAssertThrowsError(try ProcessMonitor.terminate(wrong, force: true))
        XCTAssertTrue(child.isRunning)
        try ProcessMonitor.terminate(actual, force: false)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGTERM)
    }
    func testSelfAndOtherUsersAreProtected() {
        let own = RunningProcess(id: .init(pid: getpid(), startedSeconds: 0, startedMicroseconds: 0), name: "ModelDeck", path: nil, userID: geteuid(), cpu: nil, memory: nil, gpu: nil, gpuClient: false, threads: nil)
        XCTAssertFalse(own.canTerminate)
        XCTAssertThrowsError(try ProcessMonitor.terminate(own, force: true))
        let other = RunningProcess(id: .init(pid: 100, startedSeconds: 0, startedMicroseconds: 0), name: "other", path: nil, userID: geteuid() &+ 1, cpu: nil, memory: nil, gpu: nil, gpuClient: false, threads: nil)
        XCTAssertFalse(other.canTerminate)
    }
}
