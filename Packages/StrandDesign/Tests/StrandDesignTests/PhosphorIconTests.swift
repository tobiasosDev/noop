import XCTest
import SwiftUI
@testable import StrandDesign

final class PhosphorIconTests: XCTestCase {

    /// Icons the NOOP v2 design frames reference by name.
    private let designIcons = [
        "heart-light", "lightning-light", "sparkle-light", "squares-four-light",
        "chart-line-up-light", "bed-light", "dots-three-light", "play-fill",
    ]

    func testResourceLoadsBothWeights() {
        let names = PhosphorLibrary.allNames
        XCTAssertGreaterThan(names.count, 3000)
        let light = names.filter { $0.hasSuffix("-light") }.count
        let fill = names.filter { $0.hasSuffix("-fill") }.count
        XCTAssertEqual(light + fill, names.count, "only the Light and Fill weights are bundled")
        XCTAssertGreaterThan(light, 1500)
        XCTAssertGreaterThan(fill, 1500)
    }

    func testDesignIconsExistAndDrawInsideTheGrid() {
        for name in designIcons {
            XCTAssertTrue(PhIcon.exists(name), name)
            guard let elements = PhosphorLibrary.paths(name, weight: .light) else {
                XCTFail("\(name) did not load")
                continue
            }
            XCTAssertFalse(elements.isEmpty, name)
            for element in elements {
                XCTAssertFalse(element.isEmpty, name)
                let box = element.cgPath.boundingBoxOfPath
                XCTAssertGreaterThan(box.width, 1, name)
                XCTAssertGreaterThan(box.height, 1, name)
                XCTAssertGreaterThanOrEqual(box.minX, -0.01, name)
                XCTAssertGreaterThanOrEqual(box.minY, -0.01, name)
                XCTAssertLessThanOrEqual(box.maxX, 256.01, name)
                XCTAssertLessThanOrEqual(box.maxY, 256.01, name)
            }
        }
    }

    func testNameResolution() {
        XCTAssertEqual(PhosphorLibrary.key("heart", weight: .light), "heart-light")
        XCTAssertEqual(PhosphorLibrary.key("heart", weight: .fill), "heart-fill")
        XCTAssertEqual(PhosphorLibrary.key("heart-fill", weight: .light), "heart-fill",
                       "an explicit suffix wins over the weight argument")
        XCTAssertEqual(PhosphorLibrary.key("ph:heart-light", weight: .fill), "heart-light")
        XCTAssertTrue(PhIcon.exists("heart"))
        XCTAssertTrue(PhIcon.exists("play", weight: .fill))
        XCTAssertTrue(PhIcon.exists("ph:sparkle-light"))
        // Aliases in the Iconify set resolve to their parent's drawing.
        XCTAssertTrue(PhIcon.exists("archive-box"))
    }

    func testUnknownNamesAreEmptyAndDoNotTrap() {
        XCTAssertFalse(PhIcon.exists("definitely-not-an-icon"))
        XCTAssertNil(PhosphorLibrary.paths("definitely-not-an-icon", weight: .light))
        let shape = PhosphorShape("definitely-not-an-icon")
        XCTAssertTrue(shape.path(in: CGRect(x: 0, y: 0, width: 18, height: 18)).isEmpty)
        // Building the view must not trap either.
        _ = PhIcon("definitely-not-an-icon").body
    }

    func testShapeScalesIntoTheCenteredSquare() {
        let full = PhosphorShape("square", weight: .fill).path(in: CGRect(x: 0, y: 0, width: 256, height: 256))
        let reference = full.cgPath.boundingBoxOfPath
        // A 36x18 rect: the icon is drawn 18pt square, centered horizontally.
        let rect = CGRect(x: 0, y: 0, width: 36, height: 18)
        let box = PhosphorShape("square", weight: .fill).path(in: rect).cgPath.boundingBoxOfPath
        let scale: CGFloat = 18.0 / 256.0
        XCTAssertEqual(box.minX, 9 + reference.minX * scale, accuracy: 1e-6)
        XCTAssertEqual(box.minY, reference.minY * scale, accuracy: 1e-6)
        XCTAssertEqual(box.width, reference.width * scale, accuracy: 1e-6)
        XCTAssertEqual(box.height, reference.height * scale, accuracy: 1e-6)
        XCTAssertTrue(PhosphorShape("square").path(in: .zero).isEmpty)
    }

    func testMultiElementIconsKeepTheirElements() {
        let elements = PhosphorLibrary.paths("stack-fill", weight: .fill)
        XCTAssertEqual(elements?.count, 3)
        // The combined shape covers every element.
        let combined = PhosphorShape("stack", weight: .fill).path(in: CGRect(x: 0, y: 0, width: 256, height: 256))
        let union = (elements ?? []).reduce(CGRect.null) { $0.union($1.cgPath.boundingBoxOfPath) }
        XCTAssertEqual(combined.cgPath.boundingBoxOfPath.width, union.width, accuracy: 1e-6)
    }

    /// Every bundled icon parses to the end of its data and stays on the 256 grid. This exercises the
    /// parser over ~3000 real minified paths (packed arc flags, `.5.5` numbers, implicit repeats).
    func testEveryBundledIconParsesCompletelyInsideTheGrid() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "phosphor", withExtension: "json"))
        let source = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))
        var incomplete: [String] = []
        var outside: [String] = []
        for (name, ds) in source {
            for d in ds {
                let result = SVGPathParser.parse(d)
                if !result.complete || result.path.isEmpty { incomplete.append(name) }
                let box = result.path.cgPath.boundingBoxOfPath
                if box.minX < -0.5 || box.minY < -0.5 || box.maxX > 256.5 || box.maxY > 256.5 {
                    outside.append("\(name) \(box)")
                }
            }
        }
        XCTAssertEqual(incomplete, [], "icons whose path data did not parse to the end")
        XCTAssertEqual(outside, [], "icons drawing outside the 256 grid")
    }
}
