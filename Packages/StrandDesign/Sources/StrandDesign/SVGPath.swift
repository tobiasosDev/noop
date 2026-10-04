import SwiftUI
import CoreGraphics

// MARK: - SVG path data

/// Parses SVG path data (the `d` attribute) into a SwiftUI `Path`.
///
/// Supports every path command (`M L H V C S Q T A Z`, absolute and relative), implicit
/// repetition of a command's argument list, the compact number forms SVG minifiers emit
/// (`1.5.5` is two numbers, `-.3`, `1e-3`) and arc flags packed without separators
/// (`a1 1 0 011 1`). Arcs become cubic Béziers via the endpoint-to-center conversion of the
/// SVG implementation notes (W3C SVG 1.1, appendix F.6.5), split into segments of at most 90°.
///
/// The parser is lenient in the way the SVG specification asks renderers to be: on malformed
/// data it stops and returns everything drawn up to the error, and it never traps.
/// Fill rule is the caller's choice; Phosphor bodies are drawn with the default non-zero rule.
enum SVGPathParser {

    /// The path described by `d`, in the coordinate space of the source viewBox.
    static func path(_ d: String) -> Path {
        parse(d).path
    }

    /// The path described by `d`, plus whether the whole string was consumed. `complete` is false
    /// when parsing stopped at malformed data, which `path(_:)` tolerates silently.
    static func parse(_ d: String) -> (path: Path, complete: Bool) {
        var builder = Builder()
        var scanner = Scanner(Array(d.utf8))
        let complete = builder.run(&scanner)
        return (builder.path, complete)
    }

    // MARK: Tokenizer

    fileprivate struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { index >= bytes.count }

        mutating func skipSeparators() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D, 0x0C, 0x2C: index += 1   // space, tab, LF, CR, FF, comma
                default: return
                }
            }
        }

        /// The command letter at the cursor, consumed, or nil when the next token is not one.
        mutating func command() -> UInt8? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let c = bytes[index]
            guard Scanner.isCommand(c) else { return nil }
            index += 1
            return c
        }

        /// True when the next token starts a number (so an implicit repeat follows).
        mutating func numberFollows() -> Bool {
            skipSeparators()
            guard index < bytes.count else { return false }
            let c = bytes[index]
            return Scanner.isDigit(c) || c == 0x2E || c == 0x2D || c == 0x2B   // digit . - +
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let start = index
            if index < bytes.count, bytes[index] == 0x2D || bytes[index] == 0x2B { index += 1 }
            var digits = 0
            while index < bytes.count, Scanner.isDigit(bytes[index]) { index += 1; digits += 1 }
            if index < bytes.count, bytes[index] == 0x2E {
                index += 1
                while index < bytes.count, Scanner.isDigit(bytes[index]) { index += 1; digits += 1 }
            }
            guard digits > 0 else { index = start; return nil }
            // An exponent only counts when digits follow it; otherwise the `e` is left unread.
            if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {   // e E
                var probe = index + 1
                if probe < bytes.count, bytes[probe] == 0x2D || bytes[probe] == 0x2B { probe += 1 }
                if probe < bytes.count, Scanner.isDigit(bytes[probe]) {
                    index = probe
                    while index < bytes.count, Scanner.isDigit(bytes[index]) { index += 1 }
                }
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            guard let value = Double(text), value.isFinite else { index = start; return nil }
            return CGFloat(value)
        }

        /// An arc flag: a single `0` or `1`, which may abut the next number (`011` is 0, 1, 1).
        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case 0x30: index += 1; return false
            case 0x31: index += 1; return true
            default: return nil
            }
        }

        mutating func point() -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return CGPoint(x: x, y: y)
        }

        static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

        static func isCommand(_ c: UInt8) -> Bool {
            switch c {
            case UInt8(ascii: "M"), UInt8(ascii: "m"), UInt8(ascii: "L"), UInt8(ascii: "l"),
                 UInt8(ascii: "H"), UInt8(ascii: "h"), UInt8(ascii: "V"), UInt8(ascii: "v"),
                 UInt8(ascii: "C"), UInt8(ascii: "c"), UInt8(ascii: "S"), UInt8(ascii: "s"),
                 UInt8(ascii: "Q"), UInt8(ascii: "q"), UInt8(ascii: "T"), UInt8(ascii: "t"),
                 UInt8(ascii: "A"), UInt8(ascii: "a"), UInt8(ascii: "Z"), UInt8(ascii: "z"):
                return true
            default:
                return false
            }
        }
    }

    // MARK: Path builder

    fileprivate struct Builder {
        var path = Path()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        /// Second control point of the previous C/S segment, for S reflection.
        var lastCubicControl: CGPoint?
        /// Control point of the previous Q/T segment, for T reflection.
        var lastQuadControl: CGPoint?
        var hasCurrentPoint = false

        /// Draws every command in `s`. Returns true when the data ended cleanly, false when it
        /// stopped at malformed input (everything before the error is kept).
        mutating func run(_ s: inout Scanner) -> Bool {
            var command: UInt8?
            while true {
                if let next = s.command() {
                    command = next
                } else if command == nil || !s.numberFollows() {
                    // End of data, or a token that is neither a command nor a number.
                    s.skipSeparators()
                    return s.atEnd
                }
                guard let cmd = command, execute(cmd, &s) else { return false }
                // After a moveto, further coordinate pairs are implicit linetos.
                if cmd == UInt8(ascii: "M") { command = UInt8(ascii: "L") }
                if cmd == UInt8(ascii: "m") { command = UInt8(ascii: "l") }
                // Z takes no arguments, so numbers right after it are malformed.
                if cmd == UInt8(ascii: "Z") || cmd == UInt8(ascii: "z") { command = nil }
            }
        }

        /// Executes one command with one argument group. Returns false on malformed data.
        mutating func execute(_ cmd: UInt8, _ s: inout Scanner) -> Bool {
            let relative = cmd >= UInt8(ascii: "a")
            let base = relative ? current : .zero
            let upper = relative ? cmd - 0x20 : cmd
            var cubicControl: CGPoint?
            var quadControl: CGPoint?

            switch upper {
            case UInt8(ascii: "M"):
                guard let p = s.point() else { return false }
                let target = offset(p, base)
                path.move(to: target)
                current = target
                subpathStart = target
                hasCurrentPoint = true

            case UInt8(ascii: "L"):
                guard let p = s.point() else { return false }
                lineTo(offset(p, base))

            case UInt8(ascii: "H"):
                guard let x = s.number() else { return false }
                lineTo(CGPoint(x: x + base.x, y: current.y))

            case UInt8(ascii: "V"):
                guard let y = s.number() else { return false }
                lineTo(CGPoint(x: current.x, y: y + base.y))

            case UInt8(ascii: "C"):
                guard let c1 = s.point(), let c2 = s.point(), let p = s.point() else { return false }
                ensureCurrentPoint()
                path.addCurve(to: offset(p, base), control1: offset(c1, base), control2: offset(c2, base))
                cubicControl = offset(c2, base)
                current = offset(p, base)

            case UInt8(ascii: "S"):
                guard let c2 = s.point(), let p = s.point() else { return false }
                ensureCurrentPoint()
                let c1 = lastCubicControl.map { reflect($0, about: current) } ?? current
                path.addCurve(to: offset(p, base), control1: c1, control2: offset(c2, base))
                cubicControl = offset(c2, base)
                current = offset(p, base)

            case UInt8(ascii: "Q"):
                guard let c = s.point(), let p = s.point() else { return false }
                ensureCurrentPoint()
                path.addQuadCurve(to: offset(p, base), control: offset(c, base))
                quadControl = offset(c, base)
                current = offset(p, base)

            case UInt8(ascii: "T"):
                guard let p = s.point() else { return false }
                ensureCurrentPoint()
                let c = lastQuadControl.map { reflect($0, about: current) } ?? current
                path.addQuadCurve(to: offset(p, base), control: c)
                quadControl = c
                current = offset(p, base)

            case UInt8(ascii: "A"):
                guard let rx = s.number(), let ry = s.number(), let rotation = s.number(),
                      let largeArc = s.flag(), let sweep = s.flag(), let p = s.point()
                else { return false }
                ensureCurrentPoint()
                arc(to: offset(p, base), rx: rx, ry: ry, rotationDegrees: rotation,
                    largeArc: largeArc, sweep: sweep)

            case UInt8(ascii: "Z"):
                if hasCurrentPoint { path.closeSubpath() }
                current = subpathStart

            default:
                return false
            }

            lastCubicControl = cubicControl
            lastQuadControl = quadControl
            return true
        }

        /// SVG treats a drawing command before any moveto as starting at the origin; Core
        /// Graphics would log an error instead, so an implicit moveto is inserted.
        mutating func ensureCurrentPoint() {
            if !hasCurrentPoint {
                path.move(to: current)
                subpathStart = current
                hasCurrentPoint = true
            }
        }

        mutating func lineTo(_ p: CGPoint) {
            ensureCurrentPoint()
            path.addLine(to: p)
            current = p
        }

        func reflect(_ p: CGPoint, about center: CGPoint) -> CGPoint {
            CGPoint(x: 2 * center.x - p.x, y: 2 * center.y - p.y)
        }

        /// Elliptical arc from `current` to `end` (SVG implementation notes F.6.5 / F.6.6).
        mutating func arc(to end: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                          rotationDegrees: CGFloat, largeArc: Bool, sweep: Bool) {
            let start = current
            defer { current = end }
            if start == end { return }                    // F.6.2: identical endpoints draw nothing
            var rx = abs(Double(rxIn)), ry = abs(Double(ryIn))
            if rx == 0 || ry == 0 { path.addLine(to: end); return }   // F.6.2: zero radius is a line

            let phi = Double(rotationDegrees) * .pi / 180
            let cosPhi = cos(phi), sinPhi = sin(phi)
            let x1 = Double(start.x), y1 = Double(start.y)
            let x2 = Double(end.x), y2 = Double(end.y)

            // Step 1: the start point in the ellipse's rotated frame, relative to the chord midpoint.
            let dx = (x1 - x2) / 2, dy = (y1 - y2) / 2
            let x1p = cosPhi * dx + sinPhi * dy
            let y1p = -sinPhi * dx + cosPhi * dy

            // F.6.6: scale radii up when they cannot span the endpoints.
            let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
            if lambda > 1 {
                let scale = lambda.squareRoot()
                rx *= scale
                ry *= scale
            }

            // Step 2: the center in the rotated frame.
            let rx2 = rx * rx, ry2 = ry * ry
            let numerator = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p
            let denominator = rx2 * y1p * y1p + ry2 * x1p * x1p
            var coefficient = denominator == 0 ? 0 : (max(0, numerator) / denominator).squareRoot()
            if largeArc == sweep { coefficient = -coefficient }
            let cxp = coefficient * rx * y1p / ry
            let cyp = -coefficient * ry * x1p / rx

            // Step 3: the center in user space.
            let cx = cosPhi * cxp - sinPhi * cyp + (x1 + x2) / 2
            let cy = sinPhi * cxp + cosPhi * cyp + (y1 + y2) / 2

            // Step 4: start angle and sweep extent.
            let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
            let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
            let theta1 = Builder.angle(1, 0, ux, uy)
            var delta = Builder.angle(ux, uy, vx, vy).truncatingRemainder(dividingBy: 2 * .pi)
            if !sweep && delta > 0 { delta -= 2 * .pi }
            if sweep && delta < 0 { delta += 2 * .pi }
            // Radii or coordinates near the Double range overflow above; a line keeps the outline closed.
            guard delta.isFinite, theta1.isFinite, cx.isFinite, cy.isFinite, rx.isFinite, ry.isFinite else {
                path.addLine(to: end)
                return
            }

            // Cubic approximation per segment of at most 90 degrees.
            let segments = max(1, Int((abs(delta) / (.pi / 2) - 1e-9).rounded(.up)))
            let step = delta / Double(segments)
            let k = 4.0 / 3.0 * tan(step / 4)

            func map(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: cx + rx * cosPhi * x - ry * sinPhi * y,
                        y: cy + rx * sinPhi * x + ry * cosPhi * y)
            }

            var theta = theta1
            for index in 0..<segments {
                let next = theta + step
                let cos0 = cos(theta), sin0 = sin(theta)
                let cos1 = cos(next), sin1 = sin(next)
                let control1 = map(cos0 - k * sin0, sin0 + k * cos0)
                let control2 = map(cos1 + k * sin1, sin1 - k * cos1)
                // The final segment lands exactly on the requested endpoint so no drift accumulates.
                let target = index == segments - 1 ? end : map(cos1, sin1)
                path.addCurve(to: target, control1: control1, control2: control2)
                theta = next
            }
        }

        /// Signed angle from vector u to vector v.
        static func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
    }
}

private func offset(_ point: CGPoint, _ base: CGPoint) -> CGPoint {
    CGPoint(x: point.x + base.x, y: point.y + base.y)
}
