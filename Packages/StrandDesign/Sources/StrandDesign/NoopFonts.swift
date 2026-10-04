import SwiftUI
import CoreText
import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

// MARK: - NOOP v2 typefaces
//
// Two variable fonts ship in Resources/Fonts (both SIL OFL 1.1, licence texts alongside):
//   - Hanken Grotesk (`.sans`): axis wght 100-900. Body copy and labels, usually light (300).
//   - Doto (`.dot`): axes wght 100-900 and ROND 0-100. The dot-matrix hero numerals.
// Fonts are registered for the process on first use and instantiated through CoreText variation
// attributes, so any weight on the axis is reachable, not just the named instances. When a font
// cannot be registered or resolved, the system font of the same size stands in.

/// The bundled NOOP v2 typefaces.
public enum NoopFontFace: String, CaseIterable, Sendable {
    /// Hanken Grotesk.
    case sans
    /// Doto, the dot-matrix face.
    case dot
}

/// Registration and construction of the bundled variable fonts.
public enum NoopFonts {

    /// OpenType `wght` axis tag.
    static let weightAxis = 0x7767_6874
    /// OpenType `ROND` axis tag (Doto's dot roundness).
    static let roundAxis = 0x524F_4E44

    /// Registers both bundled fonts with the process once. Safe to call from any thread, any
    /// number of times; `ctFont` and `font` call it themselves.
    public static func registerIfNeeded() {
        _ = registration
    }

    /// True when `face` is registered and resolves to the bundled font rather than a fallback.
    public static func isAvailable(_ face: NoopFontFace) -> Bool {
        registration[face] != nil
    }

    /// A CoreText font for `face` at `size` points with the `wght` axis at `weight` (100-900)
    /// and, for `.dot`, the `ROND` axis at `round` (0-100). `tabular` requests tabular figures
    /// (the OpenType `tnum` feature). Results are cached per argument set. Falls back to the
    /// system font of the same size if the bundled font is unavailable; never traps.
    public static func ctFont(_ face: NoopFontFace, size: CGFloat, weight: CGFloat,
                              round: CGFloat = 100, tabular: Bool = false) -> CTFont {
        let key = CacheKey(face: face, size: size, weight: clamp(weight, 100, 900),
                           round: face == .dot ? clamp(round, 0, 100) : 0, tabular: tabular)
        cacheLock.lock()
        if let hit = cache[key] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        let made = make(key)
        cacheLock.lock()
        cache[key] = made
        cacheLock.unlock()
        return made
    }

    /// A SwiftUI font for `face`. With `relativeTo`, the point size follows Dynamic Type for that
    /// text style where UIKit's font metrics exist (iOS, watchOS); macOS uses `size` as given.
    public static func font(_ face: NoopFontFace, size: CGFloat, weight: CGFloat,
                            round: CGFloat = 100, relativeTo style: Font.TextStyle? = nil,
                            tabular: Bool = false) -> Font {
        Font(ctFont(face, size: scaledSize(size, relativeTo: style),
                    weight: weight, round: round, tabular: tabular))
    }

    /// Hanken Grotesk at `size`, light (300) by default. Its default figures are already tabular,
    /// so live values do not reflow; `tabular` additionally requests `tnum`, which CoreText drops
    /// for faces that carry no such lookup (Hanken Grotesk 1.x among them).
    public static func sans(_ size: CGFloat, _ weight: CGFloat = 300,
                            relativeTo style: Font.TextStyle? = nil, tabular: Bool = false) -> Font {
        font(.sans, size: size, weight: weight, relativeTo: style, tabular: tabular)
    }

    /// Doto at `size`, semibold (600) with fully round dots by default.
    public static func dot(_ size: CGFloat, weight: CGFloat = 600, round: CGFloat = 100) -> Font {
        font(.dot, size: size, weight: weight, round: round)
    }

    // MARK: Registration

    private static let log = Logger(subsystem: "noop.StrandDesign", category: "NoopFonts")

    private static let resources: [NoopFontFace: String] = [
        .sans: "HankenGrotesk-Variable",
        .dot: "Doto-Variable",
    ]

    /// Base descriptor per face, taken from the registered file itself so a same-named font
    /// installed elsewhere on the system can never shadow the bundled one. Initialised exactly
    /// once; Swift guarantees thread-safe lazy initialisation of static stored properties.
    private static let registration: [NoopFontFace: CTFontDescriptor] = {
        var result: [NoopFontFace: CTFontDescriptor] = [:]
        for (face, resource) in resources {
            guard let url = fontURL(resource) else {
                log.error("Font resource \(resource, privacy: .public).ttf is missing from the bundle.")
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let cfError = error?.takeRetainedValue()
                let code = cfError.map { CFErrorGetCode($0) } ?? 0
                // Already registered (for example by a host app that bundles the same file) is fine.
                if code != CTFontManagerError.alreadyRegistered.rawValue {
                    log.error("Registering \(resource, privacy: .public) failed (code \(code)).")
                    continue
                }
            }
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                    as? [CTFontDescriptor],
                  let descriptor = descriptors.first else {
                log.error("No font descriptor in \(resource, privacy: .public).")
                continue
            }
            result[face] = descriptor
        }
        return result
    }()

    private static func fontURL(_ resource: String) -> URL? {
        // `.process` resources are flattened into the bundle root; the subdirectory is a fallback
        // for a bundle that preserves the folder.
        Bundle.module.url(forResource: resource, withExtension: "ttf")
            ?? Bundle.module.url(forResource: resource, withExtension: "ttf", subdirectory: "Fonts")
    }

    // MARK: Construction

    private struct CacheKey: Hashable {
        let face: NoopFontFace
        let size: CGFloat
        let weight: CGFloat
        let round: CGFloat
        let tabular: Bool
    }

    private static let cacheLock = NSLock()
    private static var cache: [CacheKey: CTFont] = [:]

    private static func make(_ key: CacheKey) -> CTFont {
        guard let base = registration[key.face] else {
            return systemFallback(size: key.size, weight: key.weight, tabular: key.tabular)
        }
        var variation: [NSNumber: NSNumber] = [
            NSNumber(value: weightAxis): NSNumber(value: Double(key.weight)),
        ]
        if key.face == .dot {
            variation[NSNumber(value: roundAxis)] = NSNumber(value: Double(key.round))
        }
        var attributes: [CFString: Any] = [kCTFontVariationAttribute: variation]
        if key.tabular { attributes[kCTFontFeatureSettingsAttribute] = tabularFeature }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(base, attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, key.size, nil)
    }

    private static let tabularFeature: [[CFString: Any]] = [[
        kCTFontOpenTypeFeatureTag: "tnum" as CFString,
        kCTFontOpenTypeFeatureValue: NSNumber(value: 1),
    ]]

    private static func systemFallback(size: CGFloat, weight: CGFloat, tabular: Bool) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        var attributes: [CFString: Any] = [
            kCTFontTraitsAttribute: [kCTFontWeightTrait: systemWeightTrait(weight)] as CFDictionary,
        ]
        if tabular { attributes[kCTFontFeatureSettingsAttribute] = tabularFeature }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(base), attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    /// Maps a CSS-style weight (100-900) onto CoreText's -1...1 weight trait, using the values the
    /// system fonts assign to their named weights.
    private static func systemWeightTrait(_ weight: CGFloat) -> CGFloat {
        let table: [(css: CGFloat, trait: CGFloat)] = [
            (100, -0.80), (200, -0.60), (300, -0.40), (400, 0.0), (500, 0.23),
            (600, 0.30), (700, 0.40), (800, 0.56), (900, 0.62),
        ]
        let w = clamp(weight, 100, 900)
        for (lower, upper) in zip(table, table.dropFirst()) where w <= upper.css {
            let t = (w - lower.css) / (upper.css - lower.css)
            return lower.trait + (upper.trait - lower.trait) * t
        }
        return table[table.count - 1].trait
    }

    // MARK: Dynamic Type

    private static func scaledSize(_ size: CGFloat, relativeTo style: Font.TextStyle?) -> CGFloat {
        #if canImport(UIKit)
        guard let style else { return size }
        return UIFontMetrics(forTextStyle: uiTextStyle(style)).scaledValue(for: size)
        #else
        return size
        #endif
    }

    #if canImport(UIKit)
    private static func uiTextStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
    #endif

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        guard value.isFinite else { return lower }
        return min(max(value, lower), upper)
    }
}
