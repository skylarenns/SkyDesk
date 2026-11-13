import XCTest
@testable import SkyDeskCore

final class DeferredActionTests: XCTestCase {
    /// Regression: the iPad froze because the keyboard's first responder changed inside a SwiftUI view update.
    func testActionNeverRunsInsideTheCallerAndBurstsCoalesce() {
        let deferred = DeferredAction(queue: .main)
        var runs = 0
        let done = expectation(description: "ran")
        for _ in 0..<50 { deferred.schedule { runs += 1; done.fulfill() } }
        XCTAssertEqual(runs, 0, "the action must not run before schedule returns")
        wait(for: [done], timeout: 2)
        XCTAssertEqual(runs, 1)
    }
    func testSchedulesAgainAfterRunning() {
        let deferred = DeferredAction(queue: .main)
        var runs = 0
        let first = expectation(description: "first")
        deferred.schedule { runs += 1; first.fulfill() }
        wait(for: [first], timeout: 2)
        let second = expectation(description: "second")
        deferred.schedule { runs += 1; second.fulfill() }
        wait(for: [second], timeout: 2)
        XCTAssertEqual(runs, 2)
    }
}
