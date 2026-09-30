import XCTest
@testable import OpenClip

final class SelectionEditabilityProbeTests: XCTestCase {
    @MainActor
    func testBlockedLookupRunsOffMainThreadAndReturnsFalseAtDeadline() async {
        let unblock = DispatchSemaphore(value: 0)
        let started = expectation(description: "lookup started off the main thread")
        let finished = expectation(description: "worker finished after timeout")
        let point = CGPoint(x: 120, y: 240)
        let probe = SelectionEditabilityProbe(timeout: 0.1) { pid, axPoint, deadline in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(pid, 99991)
            XCTAssertEqual(axPoint, point)
            XCTAssertGreaterThan(deadline.timeIntervalSinceNow, 0)
            started.fulfill()
            _ = unblock.wait(timeout: .now() + 2)
            finished.fulfill()
            return true
        }
        defer { unblock.signal() }
        let start = Date()
        let request = Task { await probe.isEditable(at: point, pid: 99991) }
        await fulfillment(of: [started], timeout: 1)

        // This test continues on the main actor while the AX worker remains blocked.
        let result = await request.value
        XCTAssertFalse(result, "A timed-out lookup must fail closed without waiting for its worker")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "The watchdog must return before the blocked worker")
        unblock.signal()
        await fulfillment(of: [finished], timeout: 1)
    }

    func testQuickLookupReturnsItsAnswer() async {
        for editable in [false, true] {
            let probe = SelectionEditabilityProbe(timeout: 1) { _, _, _ in editable }
            let result = await probe.isEditable(at: .zero, pid: 99991)
            XCTAssertEqual(result, editable)
        }
    }

    func testCancelledLookupCannotAuthorizeClipboardFallback() async {
        let unblock = DispatchSemaphore(value: 0)
        let started = expectation(description: "lookup started")
        let probe = SelectionEditabilityProbe(timeout: 1) { _, _, _ in
            started.fulfill()
            _ = unblock.wait(timeout: .now() + 2)
            return true
        }
        defer { unblock.signal() }
        let request = Task { await probe.isEditable(at: .zero, pid: 99991) }
        await fulfillment(of: [started], timeout: 1)
        request.cancel()
        unblock.signal()

        let result = await request.value
        XCTAssertFalse(result)
    }
}
