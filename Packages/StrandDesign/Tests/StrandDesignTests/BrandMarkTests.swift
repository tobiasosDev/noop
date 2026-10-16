import XCTest
import SwiftUI
@testable import StrandDesign

/// Pins the generated brand paths (Tools/noop_brand.py writes BrandPaths.swift) against the parser
/// that draws them, so a malformed regeneration fails here instead of drawing half a logo.
final class BrandMarkTests: XCTestCase {

    func testBothPathsParseCompletely() {
        XCTAssertTrue(SVGPathParser.parse(BrandPaths.mark).complete)
        XCTAssertTrue(SVGPathParser.parse(BrandPaths.lockup).complete)
    }

    /// The mark is centred on its 64-unit grid: 11…53 across, 10…54 down.
    func testMarkBoundingBoxIsCentredOnTheGrid() {
        let box = SVGPathParser.path(BrandPaths.mark).boundingRect
        XCTAssertEqual(box.minX, 11, accuracy: 0.01)
        XCTAssertEqual(box.maxX, 53, accuracy: 0.01)
        XCTAssertEqual(box.minY, 10, accuracy: 0.01)
        XCTAssertEqual(box.maxY, 54, accuracy: 0.01)
    }

    /// The lockup's ink fills its viewBox, so `BrandLockup(height:)` means the drawn height.
    func testLockupFillsItsViewBox() {
        let box = SVGPathParser.path(BrandPaths.lockup).boundingRect
        let view = BrandPaths.lockupViewBox
        XCTAssertEqual(box.minX, view.minX, accuracy: 0.5)
        XCTAssertEqual(box.minY, view.minY, accuracy: 0.5)
        XCTAssertEqual(box.maxX, view.maxX, accuracy: 0.5)
        XCTAssertEqual(box.maxY, view.maxY, accuracy: 0.5)
    }

    func testShapeScalesUniformlyAndCentres() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let box = BrandShape.mark.path(in: rect).boundingRect
        // 64-unit grid into a 100-pt square centred in the rect: scale 100/64.
        XCTAssertEqual(box.height, 44 * 100 / 64, accuracy: 0.01)
        XCTAssertEqual(box.midX, 100, accuracy: 0.01)
        XCTAssertEqual(box.midY, 50, accuracy: 0.01)
    }
}
