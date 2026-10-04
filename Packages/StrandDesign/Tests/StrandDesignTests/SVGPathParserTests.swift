import XCTest
import SwiftUI
@testable import StrandDesign

final class SVGPathParserTests: XCTestCase {

    // MARK: Helpers

    /// One path element. Equality is approximate because SwiftUI's `Path` stores coordinates in
    /// single precision (`-0.3` reads back as `-0.30000001`).
    private enum El: Equatable {
        case move(CGPoint)
        case line(CGPoint)
        case quad(CGPoint, CGPoint)          // to, control
        case curve(CGPoint, CGPoint, CGPoint) // to, control1, control2
        case close

        static func == (lhs: El, rhs: El) -> Bool {
            func near(_ a: CGPoint, _ b: CGPoint) -> Bool {
                abs(a.x - b.x) <= 1e-4 * max(1, abs(b.x)) && abs(a.y - b.y) <= 1e-4 * max(1, abs(b.y))
            }
            switch (lhs, rhs) {
            case let (.move(a), .move(b)), let (.line(a), .line(b)): return near(a, b)
            case let (.quad(a1, a2), .quad(b1, b2)): return near(a1, b1) && near(a2, b2)
            case let (.curve(a1, a2, a3), .curve(b1, b2, b3)): return near(a1, b1) && near(a2, b2) && near(a3, b3)
            case (.close, .close): return true
            default: return false
            }
        }
    }

    private func elements(_ d: String) -> [El] {
        var out: [El] = []
        SVGPathParser.path(d).forEach { element in
            switch element {
            case .move(let p): out.append(.move(p))
            case .line(let p): out.append(.line(p))
            case .quadCurve(let p, let c): out.append(.quad(p, c))
            case .curve(let p, let c1, let c2): out.append(.curve(p, c1, c2))
            case .closeSubpath: out.append(.close)
            }
        }
        return out
    }

    /// Tight bounding box (control points excluded).
    private func bounds(_ d: String) -> CGRect {
        SVGPathParser.path(d).cgPath.boundingBoxOfPath
    }

    private func assertRect(_ r: CGRect, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                            accuracy: CGFloat = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.minX, x, accuracy: accuracy, "minX", file: file, line: line)
        XCTAssertEqual(r.minY, y, accuracy: accuracy, "minY", file: file, line: line)
        XCTAssertEqual(r.width, w, accuracy: accuracy, "width", file: file, line: line)
        XCTAssertEqual(r.height, h, accuracy: accuracy, "height", file: file, line: line)
    }

    private func assertPoint(_ p: CGPoint?, _ x: CGFloat, _ y: CGFloat, accuracy: CGFloat = 1e-9,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let p else { return XCTFail("no point", file: file, line: line) }
        XCTAssertEqual(p.x, x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(p.y, y, accuracy: accuracy, file: file, line: line)
    }

    private func endPoint(_ d: String) -> CGPoint? {
        SVGPathParser.path(d).currentPoint
    }

    // MARK: Lines and boxes

    func testSquareFromHorizontalAndVerticalCommands() {
        let d = "M0 0h256v256H0Z"
        assertRect(bounds(d), 0, 0, 256, 256)
        XCTAssertEqual(elements(d), [
            .move(CGPoint(x: 0, y: 0)), .line(CGPoint(x: 256, y: 0)),
            .line(CGPoint(x: 256, y: 256)), .line(CGPoint(x: 0, y: 256)), .close,
        ])
        XCTAssertTrue(SVGPathParser.parse(d).complete)
    }

    func testImplicitLinetoAfterMoveto() {
        XCTAssertEqual(elements("M0 0 10 0 10 10"), [
            .move(CGPoint(x: 0, y: 0)), .line(CGPoint(x: 10, y: 0)), .line(CGPoint(x: 10, y: 10)),
        ])
        // Relative moveto: the implicit pairs are relative linetos.
        XCTAssertEqual(elements("m1 1 2 0 0 2"), [
            .move(CGPoint(x: 1, y: 1)), .line(CGPoint(x: 3, y: 1)), .line(CGPoint(x: 3, y: 3)),
        ])
        // Repeated argument groups on an explicit command.
        XCTAssertEqual(elements("M0 0l1 0 0 1h2 3v-4"), [
            .move(CGPoint(x: 0, y: 0)), .line(CGPoint(x: 1, y: 0)), .line(CGPoint(x: 1, y: 1)),
            .line(CGPoint(x: 3, y: 1)), .line(CGPoint(x: 6, y: 1)), .line(CGPoint(x: 6, y: -3)),
        ])
    }

    func testRelativeMoveAfterCloseStartsFromSubpathStart() {
        XCTAssertEqual(elements("M10 10h10v10zm5 5h1"), [
            .move(CGPoint(x: 10, y: 10)), .line(CGPoint(x: 20, y: 10)), .line(CGPoint(x: 20, y: 20)),
            .close, .move(CGPoint(x: 15, y: 15)), .line(CGPoint(x: 16, y: 15)),
        ])
    }

    // MARK: Number syntax

    func testCompactNumberForms() {
        XCTAssertEqual(elements("M1.5.5L-.3 1e1"), [
            .move(CGPoint(x: 1.5, y: 0.5)), .line(CGPoint(x: -0.3, y: 10)),
        ])
        XCTAssertEqual(elements("M0,0L1e-3,2E+1"), [
            .move(CGPoint(x: 0, y: 0)), .line(CGPoint(x: 0.001, y: 20)),
        ])
        XCTAssertEqual(elements("M0 0L5-5"), [.move(.zero), .line(CGPoint(x: 5, y: -5))])
        XCTAssertEqual(elements("M+1 -.5e1"), [.move(CGPoint(x: 1, y: -5))])
        assertRect(bounds("M1.5.5L-.3 1e1"), -0.3, 0.5, 1.8, 9.5, accuracy: 1e-5)
    }

    func testExponentLetterWithoutDigitsIsNotConsumed() {
        // `1e` is not an exponent; the parse stops at the stray letter and keeps what came before.
        let result = SVGPathParser.parse("M0 0L1e")
        XCTAssertFalse(result.complete)
        XCTAssertEqual(elements("M0 0L1e"), [.move(.zero)])
    }

    // MARK: Curves

    func testSmoothCubicReflectsPreviousControlPoint() {
        let expected: [El] = [
            .move(.zero),
            .curve(CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 10), CGPoint(x: 10, y: 10)),
            .curve(CGPoint(x: 20, y: 0), CGPoint(x: 10, y: -10), CGPoint(x: 20, y: -10)),
        ]
        XCTAssertEqual(elements("M0 0C0 10 10 10 10 0S20-10 20 0"), expected)
        XCTAssertEqual(elements("M0 0c0 10 10 10 10 0s10-10 10 0"), expected)
    }

    func testSmoothCubicWithoutPreviousCubicUsesCurrentPoint() {
        XCTAssertEqual(elements("M0 0L5 0S10 10 20 0"), [
            .move(.zero), .line(CGPoint(x: 5, y: 0)),
            .curve(CGPoint(x: 20, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 10, y: 10)),
        ])
    }

    func testSmoothQuadraticReflectsPreviousControlPoint() {
        let expected: [El] = [
            .move(.zero),
            .quad(CGPoint(x: 20, y: 0), CGPoint(x: 10, y: 10)),
            .quad(CGPoint(x: 40, y: 0), CGPoint(x: 30, y: -10)),
            .quad(CGPoint(x: 60, y: 0), CGPoint(x: 50, y: 10)),
        ]
        XCTAssertEqual(elements("M0 0Q10 10 20 0T40 0 60 0"), expected)
        XCTAssertEqual(elements("M0 0q10 10 20 0t20 0 20 0"), expected)
    }

    // MARK: Arcs

    func testCircleFromTwoArcs() {
        let d = "M10 50a40 40 0 1 0 80 0a40 40 0 1 0-80 0Z"
        assertRect(bounds(d), 10, 10, 80, 80, accuracy: 1e-6)
        // Every on-curve point sits on the circle, and the curve midpoints stay within the
        // standard 4/3·tan(θ/4) approximation error (≈ 0.027 % of the radius per 90° segment).
        let center = CGPoint(x: 50, y: 50)
        var previous = CGPoint(x: 10, y: 50)
        var curves = 0
        for element in elements(d) {
            guard case let .curve(to, c1, c2) = element else { continue }
            curves += 1
            XCTAssertEqual(hypot(to.x - center.x, to.y - center.y), 40, accuracy: 1e-9)
            let mid = CGPoint(x: 0.125 * previous.x + 0.375 * c1.x + 0.375 * c2.x + 0.125 * to.x,
                              y: 0.125 * previous.y + 0.375 * c1.y + 0.375 * c2.y + 0.125 * to.y)
            XCTAssertEqual(hypot(mid.x - center.x, mid.y - center.y), 40, accuracy: 0.02)
            previous = to
        }
        XCTAssertEqual(curves, 4, "two 180° arcs split into four 90° segments")
    }

    func testArcFlagsPackedWithoutSeparators() {
        let packed = elements("M0 0a1 1 0 011 1")
        XCTAssertEqual(packed, elements("M0 0a1 1 0 0 1 1 1"))
        XCTAssertEqual(packed.count, 2)
        assertPoint(endPoint("M0 0a1 1 0 011 1"), 1, 1)
        // Small, clockwise (in y-down space) quarter arc around (0, 1): stays in the unit box.
        assertRect(bounds("M0 0a1 1 0 011 1"), 0, 0, 1, 1, accuracy: 1e-9)
    }

    func testArcFollowedByNegativeNumberWithoutSeparator() {
        // Quarter arc from (12, 0) to (6, 6) around (6, 0), sweeping through (10.24, 4.24).
        let d = "M12 0a6 6 0 0 1-6 6"
        assertPoint(endPoint(d), 6, 6)
        assertRect(bounds(d), 6, 0, 6, 6, accuracy: 1e-9)
        XCTAssertEqual(elements(d), elements("M12 0a6,6,0,0,1,-6,6"))
    }

    func testLargeArcAndSweepFlagsChooseTheFourArcs() {
        // Same endpoints and radius; the flags pick which of the four candidate arcs is drawn.
        // Endpoints (0,0) and (10,0) with r = 10: the centers sit at (5, ±8.66).
        // Sweep 1 is the positive-angle direction, clockwise on a y-down screen, so from the left
        // endpoint to the right one both sweep-1 arcs pass over the top.
        let h = 75.0.squareRoot()
        let small = bounds("M0 0A10 10 0 0 1 10 0")   // short arc around (5, +8.66)
        XCTAssertEqual(small.minY, -(10 - h), accuracy: 1e-6)
        XCTAssertEqual(small.maxY, 0, accuracy: 1e-9)
        XCTAssertEqual(small.width, 10, accuracy: 1e-9)
        // The 300° long arc is cut into four 75° cubics, so its extremes fall mid-segment and carry
        // the cubic approximation's overshoot (at most ~0.03 % of the radius, here 0.003).
        let large = bounds("M0 0A10 10 0 1 1 10 0")   // long arc around (5, -8.66)
        XCTAssertEqual(large.minY, -(h + 10), accuracy: 0.003)
        XCTAssertEqual(large.maxY, 0, accuracy: 1e-9)
        XCTAssertEqual(large.minX, -5, accuracy: 0.003)
        XCTAssertEqual(large.width, 20, accuracy: 0.006)
        // Sweep 0 mirrors both below the chord.
        let smallDown = bounds("M0 0A10 10 0 0 0 10 0")
        XCTAssertEqual(smallDown.maxY, 10 - h, accuracy: 1e-6)
        XCTAssertEqual(smallDown.minY, 0, accuracy: 1e-9)
        let largeDown = bounds("M0 0A10 10 0 1 0 10 0")
        XCTAssertEqual(largeDown.maxY, h + 10, accuracy: 0.003)
    }

    func testArcRadiiScaleUpWhenTooSmall() {
        // Radius 1 cannot span 10 units; it scales to 5, giving a half circle above the chord.
        let d = "M0 0A1 1 0 0 1 10 0"
        assertRect(bounds(d), 0, -5, 10, 5, accuracy: 1e-6)
        assertPoint(endPoint(d), 10, 0)
    }

    func testRotatedEllipse() {
        // rx 20, ry 10 rotated 90°: the major axis is vertical, so the ellipse is 20 wide, 40 tall.
        let d = "M0 -20A20 10 90 1 0 0 20A20 10 90 1 0 0 -20Z"
        assertRect(bounds(d), -10, -20, 20, 40, accuracy: 1e-6)
    }

    func testDegenerateArcs() {
        // Zero radius: a straight line.
        XCTAssertEqual(elements("M0 0A0 5 0 0 1 10 0"), [.move(.zero), .line(CGPoint(x: 10, y: 0))])
        // Identical endpoints: nothing is drawn, the current point stays put.
        XCTAssertEqual(elements("M3 4A5 5 0 0 1 3 4"), [.move(CGPoint(x: 3, y: 4))])
        // Negative radii are taken as absolute values.
        XCTAssertEqual(elements("M0 0a-1-1 0 011 1"), elements("M0 0a1 1 0 011 1"))
    }

    // MARK: Malformed input

    func testMalformedDataKeepsWhatCameBeforeTheError() {
        XCTAssertEqual(elements("M0 0L10 10L"), [.move(.zero), .line(CGPoint(x: 10, y: 10))])
        XCTAssertFalse(SVGPathParser.parse("M0 0L10 10L").complete)
        XCTAssertEqual(elements("M0 0L1"), [.move(.zero)])
        XCTAssertEqual(elements("M0 0zx5"), [.move(.zero), .close])
        XCTAssertFalse(SVGPathParser.parse("M0 0z 5 5").complete)
        XCTAssertTrue(SVGPathParser.path("garbage").isEmpty)
        XCTAssertTrue(SVGPathParser.path("").isEmpty)
        XCTAssertTrue(SVGPathParser.parse("  ").complete)
        XCTAssertFalse(SVGPathParser.parse("M0 0A1 1 0 2 1 5 5").complete, "flags must be 0 or 1")
        XCTAssertFalse(SVGPathParser.parse("M1e999 0").complete, "non-finite numbers are rejected")
    }

    func testDrawingBeforeMovetoStartsAtOrigin() {
        XCTAssertEqual(elements("L10 0"), [.move(.zero), .line(CGPoint(x: 10, y: 0))])
    }
}
