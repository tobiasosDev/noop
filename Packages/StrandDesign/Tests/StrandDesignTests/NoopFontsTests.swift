import XCTest
import CoreText
import SwiftUI
@testable import StrandDesign

final class NoopFontsTests: XCTestCase {

    /// Axis tag -> value for every variation axis of `font`. CoreText reports only the axes moved
    /// off their default, so the remaining axes are filled in from the font's axis table.
    private func variation(_ font: CTFont) -> [Int: Double] {
        var values: [Int: Double] = [:]
        for axis in CTFontCopyVariationAxes(font) as? [[String: Any]] ?? [] {
            guard let id = axis[kCTFontVariationAxisIdentifierKey as String] as? NSNumber,
                  let fallback = axis[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber
            else { continue }
            values[id.intValue] = fallback.doubleValue
        }
        let set = CTFontCopyVariation(font) as? [NSNumber: NSNumber] ?? [:]
        for (id, value) in set { values[id.intValue] = value.doubleValue }
        return values
    }

    func testBundledFontsRegister() {
        NoopFonts.registerIfNeeded()
        NoopFonts.registerIfNeeded()   // idempotent
        XCTAssertTrue(NoopFonts.isAvailable(.sans))
        XCTAssertTrue(NoopFonts.isAvailable(.dot))
    }

    func testDotFontAppliesWeightAndRoundness() {
        let font = NoopFonts.ctFont(.dot, size: 64, weight: 600, round: 100)
        XCTAssertEqual(CTFontCopyFamilyName(font) as String, "Doto")
        XCTAssertEqual(CTFontGetSize(font), 64)
        let axes = variation(font)
        XCTAssertEqual(axes[NoopFonts.weightAxis] ?? -1, 600, accuracy: 0.5)
        XCTAssertEqual(axes[NoopFonts.roundAxis] ?? -1, 100, accuracy: 0.5)

        let square = variation(NoopFonts.ctFont(.dot, size: 64, weight: 300, round: 0))
        XCTAssertEqual(square[NoopFonts.weightAxis] ?? -1, 300, accuracy: 0.5)
        XCTAssertEqual(square[NoopFonts.roundAxis] ?? -1, 0, accuracy: 0.5)
    }

    func testSansFontAppliesWeight() {
        for weight: CGFloat in [300, 400, 500, 600, 700] {
            let font = NoopFonts.ctFont(.sans, size: 17, weight: weight)
            XCTAssertEqual(CTFontCopyFamilyName(font) as String, "Hanken Grotesk")
            XCTAssertEqual(variation(font)[NoopFonts.weightAxis] ?? -1, Double(weight), accuracy: 0.5)
        }
    }

    func testWeightIsClampedToTheAxis() {
        let light = variation(NoopFonts.ctFont(.sans, size: 12, weight: 20))
        XCTAssertEqual(light[NoopFonts.weightAxis] ?? -1, 100, accuracy: 0.5)
        let heavy = variation(NoopFonts.ctFont(.dot, size: 12, weight: 2000, round: 400))
        XCTAssertEqual(heavy[NoopFonts.weightAxis] ?? -1, 900, accuracy: 0.5)
        XCTAssertEqual(heavy[NoopFonts.roundAxis] ?? -1, 100, accuracy: 0.5)
    }

    func testFontsAreCached() {
        let a = NoopFonts.ctFont(.sans, size: 15, weight: 300)
        let b = NoopFonts.ctFont(.sans, size: 15, weight: 300)
        XCTAssertTrue(a === b)
        let tabular = NoopFonts.ctFont(.sans, size: 15, weight: 300, tabular: true)
        XCTAssertFalse(a === tabular)
    }

    /// Live values must not reflow. Hanken Grotesk's default figures are already tabular and the
    /// font carries no `tnum` lookup, so CoreText drops the `tabular` request at font creation;
    /// the contract that matters, one shared advance for all ten digits, holds either way.
    func testFiguresShareOneAdvance() {
        for tabular in [false, true] {
            let font = NoopFonts.ctFont(.sans, size: 40, weight: 300, tabular: tabular)
            let widths = "0123456789".map { digit -> Double in
                let text = NSAttributedString(
                    string: String(digit),
                    attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil)
            }
            XCTAssertLessThan((widths.max() ?? 0) - (widths.min() ?? 0), 0.05, "tabular: \(tabular)")
        }
    }

    func testSwiftUIWrappersBuild() {
        _ = NoopFonts.sans(15)
        _ = NoopFonts.sans(15, 500, relativeTo: .body, tabular: true)
        _ = NoopFonts.dot(72)
        _ = NoopFonts.font(.dot, size: 48, weight: 700, round: 50, relativeTo: .largeTitle)
    }
}
