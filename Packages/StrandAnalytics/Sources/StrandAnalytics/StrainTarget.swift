import Foundation

// StrainTarget.swift — recovery-driven exertion guidance.
//
// Maps today's recovery % onto a recommended strain band on the 0–21 scale.
// APPROXIMATION of published recovery→load coaching heuristics (not WHOOP's
// proprietary mapping). Constants live here so the curve is tunable in one place.

public enum StrainTarget {

    /// Band half-width around the midpoint.
    public static let halfWidth: Double = 1.0
    /// Linear map: recovery 0 → 4.0, recovery 100 → 18.5.
    static let base: Double = 4.0
    static let slope: Double = 0.145

    public enum State: String, Equatable, Sendable {
        case building       // below the band — room to push
        case onTarget       // inside the band
        case overreaching   // above the band — exceeding today's recommendation
    }

    public struct Band: Equatable, Sendable {
        public let low: Double
        public let high: Double
        public var midpoint: Double { (low + high) / 2 }

        /// Band edges are inclusive.
        public func state(currentStrain: Double) -> State {
            if currentStrain < low { return .building }
            if currentStrain > high { return .overreaching }
            return .onTarget
        }
    }

    /// Recommended strain band for a recovery score (0–100; out-of-range input clamps).
    public static func band(recovery: Double) -> Band {
        let r = min(100, max(0, recovery))
        let mid = base + slope * r
        return Band(low: max(0, mid - halfWidth), high: min(21, mid + halfWidth))
    }
}
