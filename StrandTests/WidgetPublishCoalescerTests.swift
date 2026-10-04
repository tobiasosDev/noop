import XCTest
import Foundation
@testable import Strand

/// `WidgetPublishCoalescer`: one trailing publish per burst, and a full publish absorbs a waiting request.
@MainActor
final class WidgetPublishCoalescerTests: XCTestCase {

    private func settle() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    func testABurstOfRequestsPublishesOnce() async {
        let coalescer = WidgetPublishCoalescer(delayNanoseconds: 50_000_000)
        var fired = 0
        for _ in 0..<5 { coalescer.request { fired += 1 } }
        await settle()
        XCTAssertEqual(fired, 1)
        XCTAssertFalse(coalescer.hasPending)
    }

    func testAFullPublishAbsorbsAWaitingRequest() async {
        let coalescer = WidgetPublishCoalescer(delayNanoseconds: 50_000_000)
        var fired = 0
        coalescer.request { fired += 1 }
        XCTAssertTrue(coalescer.hasPending)
        coalescer.satisfyPending()
        await settle()
        XCTAssertEqual(fired, 0)
    }

    func testARequestAfterAPublishPublishesAgain() async {
        let coalescer = WidgetPublishCoalescer(delayNanoseconds: 50_000_000)
        var fired = 0
        coalescer.request { fired += 1 }
        await settle()
        coalescer.request { fired += 1 }
        await settle()
        XCTAssertEqual(fired, 2)
    }

    /// The fired publish calls `satisfyPending()` itself (as `WidgetSnapshot.publish` does); that must not
    /// cancel the publish that is running.
    func testThePublishItselfCannotCancelItself() async {
        let coalescer = WidgetPublishCoalescer(delayNanoseconds: 50_000_000)
        var completed = false
        coalescer.request {
            coalescer.satisfyPending()
            try? await Task.sleep(nanoseconds: 20_000_000)
            completed = !Task.isCancelled
        }
        await settle()
        XCTAssertTrue(completed)
    }
}
