import XCTest
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
@testable import StrandDesign

/// Pins the main-thread hitch round's StrandDesign changes, which must leave every output unchanged.
///
/// - The v2 containers build their content ONCE in `init` and store the value. A stored builder closure
///   never compares equal to the previous pass's, so SwiftUI re-ran the whole subtree on every parent pass.
///   Reverting a container to a stored closure is silent (it renders identically), so the contract is
///   pinned here: the builder runs exactly once, inside `init`.
/// - `YearHeatStrip.v2Color` returns five prebuilt colours instead of building a new dynamic colour (and
///   parsing two hex strings) per cell per pass. The colours must resolve to the same hexes as before.
/// - `RecoveryDay.id` is its date instead of a fresh `UUID()` per init.
/// - `NoopFonts.font` caches the SwiftUI `Font`; `NoopFonts.prewarm()` and `PhIcon.prewarm()` load off-main.
final class HitchRoundKitTests: XCTestCase {

    // MARK: Containers store their content

    func testContainersRunTheirBuilderOnceInInit() {
        var calls = 0
        func text() -> Text { calls += 1; return Text(verbatim: "x") }
        func check(_ name: String, _ make: () -> Void) {
            calls = 0
            make()
            XCTAssertEqual(calls, 1, "\(name) must build its content exactly once, in init")
        }
        check("NoopCard") { _ = NoopCard { text() } }
        check("StrandCard") { _ = StrandCard { text() } }
        check("StatTile") { _ = StatTile(label: "L", value: "1") { text() } }
        check("ChartCard.chart") { _ = ChartCard(title: "T") { text() } }
        check("NoopHeroCard") { _ = NoopHeroCard(glow: .recovery) { text() } }
        check("NoopMetricRow") { _ = NoopMetricRow { text() } }
        check("NoopList") { _ = NoopList { text() } }
        check("NoopCardHeader") { _ = NoopCardHeader(verbatim: "T") { text() } }
        check("NoopSectionTitle") { _ = NoopSectionTitle(verbatim: "T") { text() } }
        check("NoopPageTitle") { _ = NoopPageTitle("T") { text() } }
        check("NoopRow") { _ = NoopRow(verbatim: "T") { text() } }
        check("NoopDetailHeader") { _ = NoopDetailHeader(verbatim: "T", onBack: nil) { text() } }
        check("NoopScreenHeader") { _ = NoopScreenHeader(verbatim: "T") { text() } }
        calls = 0
        _ = ChartCard(title: "T", chart: { text() }, footer: { text() })
        XCTAssertEqual(calls, 2, "ChartCard builds chart and footer once each, in init")
    }

    // MARK: Year heat strip

    /// The table `v2Color` built inline before the ramp became five stored colours, verbatim.
    private func previousV2Hexes(_ score: Double) -> (light: String, dark: String) {
        switch score {
        case ..<25: return ("#D9D8D4", "#232328")
        case ..<50: return ("#BFDCCB", "#20402F")
        case ..<70: return ("#8CC7A4", "#27603F")
        case ..<88: return ("#4FAE76", "#349055")
        default:    return ("#2E9A5E", "#56D08A")
        }
    }

    private let scores: [Double] = [-5, 0, 10, 24.99, 25, 40, 49.99, 50, 60, 69.99, 70, 80, 87.99, 88, 95, 100, 140]

    #if canImport(AppKit)
    private func resolved(_ color: Color, dark: Bool) -> (r: Double, g: Double, b: Double, a: Double)? {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var out: (Double, Double, Double, Double)?
        appearance.performAsCurrentDrawingAppearance {
            if let c = NSColor(color).usingColorSpace(.sRGB) {
                out = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent),
                       Double(c.alphaComponent))
            }
        }
        return out
    }

    func testV2RampResolvesToThePreviousHexesInBothAppearances() throws {
        for score in scores {
            let hexes = previousV2Hexes(score)
            for dark in [false, true] {
                let got = try XCTUnwrap(resolved(YearHeatStrip.v2Color(score), dark: dark), "\(score)")
                let want = Color.sRGBComponents(hex: dark ? hexes.dark : hexes.light)
                XCTAssertEqual(got.r, want.r, accuracy: 1e-4, "\(score) dark=\(dark)")
                XCTAssertEqual(got.g, want.g, accuracy: 1e-4, "\(score) dark=\(dark)")
                XCTAssertEqual(got.b, want.b, accuracy: 1e-4, "\(score) dark=\(dark)")
                XCTAssertEqual(got.a, want.a, accuracy: 1e-4, "\(score) dark=\(dark)")
            }
        }
    }
    #endif

    func testV2RampHandsOutOneColourPerBand() {
        for score in scores {
            XCTAssertEqual(YearHeatStrip.v2Color(score), YearHeatStrip.v2Color(score), "\(score)")
        }
        XCTAssertEqual(YearHeatStrip.v2Color(10), YearHeatStrip.v2Color(24))
        XCTAssertNotEqual(YearHeatStrip.v2Color(10), YearHeatStrip.v2Color(30))
    }

    func testRecoveryDayIdIsStableAcrossInits() {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertEqual(RecoveryDay(date: date, score: 50).id, RecoveryDay(date: date, score: nil).id)
        XCTAssertNotEqual(RecoveryDay(date: date, score: 50).id,
                          RecoveryDay(date: date.addingTimeInterval(86_400), score: 50).id)
    }

    // MARK: Fonts and icons

    func testFontIsCachedPerArgumentSet() {
        XCTAssertEqual(NoopFonts.font(.sans, size: 15, weight: 300), NoopFonts.font(.sans, size: 15, weight: 300))
        XCTAssertEqual(NoopFonts.sans(12, 400, relativeTo: .caption, tabular: true),
                       NoopFonts.sans(12, 400, relativeTo: .caption, tabular: true))
        XCTAssertNotEqual(NoopFonts.font(.sans, size: 15, weight: 300), NoopFonts.font(.sans, size: 15, weight: 400))
        XCTAssertNotEqual(NoopFonts.font(.sans, size: 15, weight: 300), NoopFonts.font(.sans, size: 16, weight: 300))
        // Weight clamps to the axis exactly as `ctFont` does, so out-of-range weights share the clamped entry.
        XCTAssertEqual(NoopFonts.font(.dot, size: 40, weight: 2000, round: 400),
                       NoopFonts.font(.dot, size: 40, weight: 900, round: 100))
    }

    func testFontPrewarmIsIdempotentAndRegisters() {
        NoopFonts.prewarm()
        NoopFonts.prewarm()
        XCTAssertTrue(NoopFonts.isAvailable(.sans))
        XCTAssertTrue(NoopFonts.isAvailable(.dot))
    }

    func testIconPrewarmFillsTheSameCache() {
        PhIcon.prewarm()
        PhIcon.prewarm()
        // `allNames` takes the library lock, so it waits for an in-flight background load.
        XCTAssertGreaterThan(PhosphorLibrary.allNames.count, 3000)
        XCTAssertTrue(PhIcon.exists("heart"))
    }
}
