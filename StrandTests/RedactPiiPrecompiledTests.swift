import XCTest
@testable import Strand

/// `LiveState.redactPii` with its rules compiled once and each one skipped on a line that lacks the bytes
/// it cannot match without (main-thread hitch: every strap-log line runs through it on the main actor).
///
/// The rewrite must not change one byte of any line, so the function as it stood before is kept below,
/// verbatim, as the oracle, and both run over a corpus: lines sampled from a real strap log (strap
/// console output with NULs and U+FFFD inside), the same lines with identifiers put back where the export
/// had masked them, every identifier shape the rules exist for, the 48 KB "sleep SKIPPED" line, and a
/// seeded spread of random lines built from the characters the rules key on.
///
/// When a rule changes ON PURPOSE, change the oracle the same way: this pins the rewrite, not the rules.
final class RedactPiiPrecompiledTests: XCTestCase {

    // MARK: - The oracle: `redactPii` before the rewrite, verbatim

    private static let legacyHexRunRegex = try? NSRegularExpression(pattern: "[0-9a-fA-F]{16,}")

    private static func legacyRedactPii(_ s: String) -> String {
        var out = s
        if let re = Self.legacyHexRunRegex {
            let ns = out as NSString
            let matches = re.matches(in: out, range: NSRange(location: 0, length: ns.length))
            if !matches.isEmpty {
                var rebuilt = ""
                var last = 0
                for m in matches {
                    rebuilt += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                    rebuilt += LiveState.redactHexDump(ns.substring(with: m.range))
                    last = m.range.location + m.range.length
                }
                rebuilt += ns.substring(from: last)
                out = rebuilt
            }
        }
        out = out.replacingOccurrences(
            of: "([0-9A-Fa-f]{2}):[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:([0-9A-Fa-f]{2})",
            with: "$1:••:••:••:••:$2", options: .regularExpression)
        out = out.replacingOccurrences(
            of: "WHOOP (?=[0-9A-Za-z]{6,})[0-9A-Za-z]*[0-9][0-9A-Za-z]*", with: "WHOOP <serial>", options: .regularExpression)
        out = out.replacingOccurrences(
            of: "(?![0-9A-Fa-f]{8}-(?:0000-1000-8000-00805f9b34fb|8d6d-82b8-614a-1c8cb0f8dcc6))[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
            with: "<device>", options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(
            of: "whoop-([A-Za-z0-9]{3})[A-Za-z0-9-]{3,}(-noop)",
            with: "whoop-$1…$2", options: .regularExpression)
        out = out.replacingOccurrences(
            of: "whoop-([A-Za-z0-9]{3})[A-Za-z0-9-]{3,}",
            with: "whoop-$1…", options: .regularExpression)
        out = out.replacingOccurrences(
            of: "oura-([A-Za-z0-9]{3})[A-Za-z0-9-]{3,}(-noop)",
            with: "oura-$1…$2", options: .regularExpression)
        out = out.replacingOccurrences(
            of: "oura-([A-Za-z0-9]{3})[A-Za-z0-9-]{3,}",
            with: "oura-$1…", options: .regularExpression)
        out = out.replacingOccurrences(
            of: "[\\p{L}\\p{N}_.\\-]+(['\u{2019}]s\\s+(?i:whoop))",
            with: "<name>$1", options: .regularExpression)
        return out
    }

    // MARK: - Corpus

    private static let strapLogSample: [String] = [
        // Sampled from a strap log exported from an iPhone, so the export had already masked its ids;
        // `unmasked` below puts identifiers back.
        "[11:15:35] send(Disable Alarm) ignored — not connected",
        "re-score: done — scored 0 night(s) in 1952 ms (#1005)",
        "[11:15:44] Central state: 5 (5 = poweredOn)",
        "[11:15:44] Found existing WHOOP 4.0 connection <device> — attaching",
        "[11:15:44] Services discovered: 61080001-8D6D-82B8-614A-1C8CB0F8DCC6, 180D, 180F, 180A",
        "[11:15:44] Notify requested 61080003-8D6D-82B8-614A-1C8CB0F8DCC6 (discovery)",
        "[11:15:44] BONDED (confirmed write acknowledged) — custom channels should now flow",
        "[11:15:44] → Get Hello (Harvard) payload=00",
        "[11:15:44] → Set Clock payload=4019c26a00000000",
        "[11:15:44] Notify active 61080003-8D6D-82B8-614A-1C8CB0F8DCC6",
        "[11:15:45] Notify active Battery Level",
        "[connection] clock: GET_CLOCK(11) reply byte@resultOffset=0x01 frame=aa14000324680b08014119c26a602200000000004c4229f6",
        "Command response: SEND_R10_R11_REALTIME(63) → PENDING(2)",
        "[11:15:45] Get Data Range raw frame (#451 — for offset analysis): aa4c00a7246b220a010180480000114800004d48000011480000110000000000020052020000a8fd1300e654536ab00500000617c26ac81800000617c26ac81800003719c26a584c00000000ccd5757a",
        "[11:15:45] Strap newest banked record: 2026-10-04 09:15:35 (from data range)",
        "strap: j\u{FFFD}x4\u{0}\u{1}: Command Link Valid",
        "strap: j\u{FFFD}Z4\u{0}\u{1}: Command Send Historical Data",
        " 29, 485179413: BLE: Codemem OK",
        " 29, 485",
        "strap: j\u{FFFD}Z4\u{0}\u{1}11:000047d8 (17:18392)",
        " 29",
        "strap: j\u{FFFD}Z4\u{0}\u{1}burst success. Trim: 0x00000011:00004804 (17:18436",
        "strap: j\u{10}[4\u{0}\u{1}84991: BLE: PullStats: Data: 660, Events: 118, Byt",
        "[11:15:46] Backfill: hist clock chunk=1 offset=+0s staleGate=closed rr=12 secs=8 pack=1.50 max=3 span=8s dens=1.50",
        "[11:15:46] → Historical Data Result payload=011448000011000000",
        "strap: j F4\u{0}\u{1}E: Cmd Set R10+R11 Realtime Stream (1)",
        "strap: j\u{FFFD}14\u{0}\u{1}ime raw R10+R11 enabled",
        "strap: jp\u{8}4\u{0}\u{1} BLE: Command Link Valid",
        " 29, 485327582: BLE: Cmd Set R10+R11 Realtim",
        " 29, 485377593: BLE: C",
        "strap: j\u{10}64\u{0}\u{1}29, 485417585: BLE: Cmd Set R10+R11 Realtime Strea",
        "strap: j\u{FFFD}\u{C}4\u{0}\u{1}: Command Link Valid",
        "strap: jP\u{15}4\u{0}\u{1}ed",
        "strap: j\u{FFFD}\u{1D}4\u{0}\u{1}lid",
        "strap: j\u{FFFD}t4\u{0}\u{1}mand Link Valid",
        "strap: jh.4\u{0}\u{1}enabled",
        "strap: j8\u{5}4\u{0}\u{1}raw R10+R11 enabled",
        "strap: j\u{FFFD}z4\u{0}\u{1} 255, 255",
        "strap: j\u{FFFD}z4\u{0}\u{1}55",
        "strap: j\u{0}{4\u{0}\u{1}8:      Trigger Conn idx: 0",
        "strap: j\u{10}{4\u{0}\u{1}rigger Conn idx: 0",
        "strap: j\u{18}{4\u{0}\u{1}C CMD CRC FAILURE 4",
        "strap: j {4\u{0}\u{1}et Clock {1791105345, 8800}",
        "strap: j {4\u{0}\u{1}nknown payload contents type (0x00).",
        " 29, 485746899:         E",
        " 29, 485747017:         Event Trig",
        "strap: jX{4\u{0}\u{1} Nordic Conn Status",
        "strap: j(}4\u{0}\u{1}RIC CMD CRC FAILURE 4",
        "strap: j(}4\u{0}\u{1}ERIC CMD CRC FAILURE 4",
        "strap: j\u{FFFD}k4\u{0}\u{1}5749640: BLE: Historical send timeout at data, req",
        "strap: j\u{FFFD}k4\u{0}\u{1}ayload contents type (0x00).",
        "strap: j\u{FFFD}k4\u{0}\u{1}tory burst success. Trim: 0x00000011:0000482d (17:",
        "strap: j\u{FFFD}:4\u{0}\u{1}ther packet.",
        "strap: j\u{FFFD}:4\u{0}\u{1}",
        "strap: j\u{FFFD}:4\u{0}\u{1}6: BLE: History burst success. Trim: 0x00000011:00",
        "re-score: trigger=post-offload newData=yes",
        "[11:16:15] rr emit path=live-realtime offered=4 inserted=n/a secs=3 sumRr=3s span=3s ratio=1.04 ratioRep=1.04 perSec[1/2/3/4+]=2/1/0/0 modalGap=1s fill[<=1/<=1.5/<=2/>2]=1/0/1/0",
        "strap: jXQ4\u{0}\u{1}ry burst success. Trim: 0x00000011:00004850 (17:18",
        " 29, 485769617: BLE: BL",
        " 29, 485770105: BLE: R10+R11 data packet transmi",
        "[11:16:18] Extended-battery probe (#592):",
        "Δ vs previous capture: first capture — probe again at another battery % to diff",
        "strap: jHC4\u{0}\u{1}Entry.",
        "strap: j0`4\u{0}\u{1}nk Valid",
        "strap: j\u{FFFD}\u{1A}4\u{0}\u{1}E: Command Disable Alarm",
        "[11:17:57] banked this link: live hr=88 rr=114 | offload hr=599 rr=305 gravity=678 resp=678 skinTemp=678 spo2=678",
        " 29, 485866464: BLE: Enabled Entry.",
        "strap: j\u{FFFD}D4\u{0}\u{1}Trim: 0x00000011:0000485c (17:18524)",
        "strap: j\u{FFFD}D4\u{0}\u{1}_SPI_GOT_HIST_PACKET_SIG caught by backstop.",
        " 29, 485870123: BLE: PullStats: ",
        "strap: jHr4\u{0}\u{1} 29, 485878640: BLE: Enabled Entry.",
        "strap: jXr4\u{0}\u{1}, 485878659:             HRS Conns: 255, 255",
        "strap: j\u{FFFD}\u{11}4\u{0}\u{1}          HRS Conns: 255, 255",
        "strap: j\u{FFFD}\u{11}4\u{0}\u{1}s: 248, 251",
        " 29, 485884389:      Trigger Con",
        "strap: j\u{FFFD}\u{11}4\u{0}\u{1} 29, 485884509:     Disconnect reason: 0",
        "[11:18:27] → Toggle Realtime HR payload=01",
        "[11:19:00] → Get Alarm Time payload=01",
    ]

    /// The identifiers the export masked, put back, so the sampled lines exercise the rules that fire.
    private static func unmasked(_ line: String) -> String {
        line.replacingOccurrences(of: "<device>", with: "1B2C3D4E-5F60-7182-93A4-B5C6D7E8F901")
            .replacingOccurrences(of: "WHOOP <serial>", with: "WHOOP 4C1594026")
            .replacingOccurrences(of: "whoop-4C1…", with: "whoop-4C1594026")
    }

    private static let identifierShapes: [String] = [
        "Discovered Ryan's Whoop (rssi -55) - connecting",
        "Discovered Ryan\u{2019}s WHOOP 4.0 (1B2C3D4E-5F60-7182-93A4-B5C6D7E8F901) rssi=-60",
        "Ryan B's Whoop, Ryan's whoop, Ryan's WHOOPS, Ryan 's Whoop, Ryan'sWhoop, O'Brien's\tWHOOP 5.0 MG",
        "Ann-Marie.K_2's whoop and Zoë's Whoop and 李's whoop and ٣'s whoop",
        "mac AA:BB:CC:DD:EE:FF, aa:bb:cc:dd:ee:ff, Aa:0b:C1:d2:E3:f4:99, AA-BB-CC-DD-EE-FF, AA:BB:CC:DD:EE",
        "time 12:34:56:78 and ipv6 fe80::1:2:3:4 and 2001:db8:85a3:0:0:8a2e:370:7334",
        "WHOOP 4C1594026 / WHOOP MGB0779473 / WHOOP PUFFIN service 1150 / WHOOP 4.0 / WHOOP 12345",
        "WHOOP ABCDEF WHOOP ABCDE1 WHOOP 1 WHOOPWHOOP 4C1594026 whoop 4C1594026",
        "whoop-4C1594026 whoop-4C1594026-noop my-whoop my-whoop-noop whoop-AB whoop-ABC-DEF whoop-ABCDEF-noop-noop",
        "oura-ABCD12345 oura-ABCD12345-noop oura-x oura-ABC oura-ABC-123",
        "ryan@example.com, mailto:first.last+tag@sub.example.org, 192.168.1.20, 10.0.0.255:8080",
        "0000180d-0000-1000-8000-00805f9b34fb 61080001-8d6d-82b8-614a-1c8cb0f8dcc6 61080001-8D6D-82B8-614A-1C8CB0F8DCC6",
        "0000180D-0000-1000-8000-00805F9B34FB 1b2c3d4e-5f60-7182-93a4-b5c6d7e8f901 1B2C3D4E5F6071829 3A4B5C6D7E8F901",
        "x1B2C3D4E-5F60-7182-93A4-B5C6D7E8F9012 and 1B2C3D4E-5F60-7182-93A4-B5C6D7E8F90",
        "[event] 0x6D(109) payload=142e1c0001d36e3d1c12a3574242354150303533393835320000",
        "frame=4242354150303533393835 (raw 0123456789abcdef0) [raw 4142434445464748494a4b4c]",
        "",
        " ",
        "'",
        "\u{2019}s whoop",
        "\u{0}\u{1}\u{FFFD}strap: j\u{FFFD}x4\u{0}\u{1}: Command Link Valid",
        "e\u{301}WHOOP 4C1594026 \u{0600}WHOOP 4C1594026 \u{1F600}whoop-ABC123 a\u{200D}b:cd:ef:01:23:45",
        "\u{FF21}\u{FF22}:CD:EF:01:23:45 \u{212A}'s whoop \u{FB00}:00:11:22:33:44 \u{1E9A}0000000-0000-0000-0000-000000000000",
        "multi\nline 1B2C3D4E-5F60-7182-93A4-B5C6D7E8F901\nRyan's Whoop\r\nAA:BB:CC:DD:EE:FF",
    ]

    /// The re-score line that lists every skipped day: 4,000 of them on a fresh install, ~48 KB.
    private static var sleepSkippedLine: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        let days = (0..<4000).map { f.string(from: Date(timeIntervalSince1970: 1_445_558_400 + Double($0) * 86_400)) }
        return "sleep SKIPPED 4000 day(s) — need ≥200 hrSamples: hrSamples=0 on 4000 day(s): "
            + days.joined(separator: ", ")
    }

    /// Deterministic lines from the pieces the rules key on, in every order and mix.
    private static func fuzzLines(count: Int, seed: UInt64) -> [String] {
        var state = seed
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        func pick<T>(_ xs: [T]) -> T { xs[Int(next() % UInt64(xs.count))] }
        let hex = Array("0123456789abcdefABCDEF")
        func hexRun(_ n: Int) -> String { String((0..<n).map { _ in pick(hex) }) }
        let pieces: [() -> String] = [
            { hexRun(Int(next() % 24) + 1) },
            { (0..<6).map { _ in hexRun(2) }.joined(separator: pick([":", ":", "-", ""])) },
            { [hexRun(8), hexRun(4), hexRun(4), hexRun(4), hexRun(12)].joined(separator: "-") },
            { pick(["0000180d-0000-1000-8000-00805f9b34fb", "61080001-8D6D-82B8-614A-1C8CB0F8DCC6"]) },
            { "WHOOP " + hexRun(Int(next() % 10)) },
            { pick(["whoop-", "oura-"]) + hexRun(Int(next() % 12)) + pick(["", "-noop", "-", "-x"]) },
            { pick(["Ryan", "Zoë", "A.B", "x_1", ""]) + pick(["'", "\u{2019}"]) + pick(["s ", "s\t", "s", "S "])
                + pick(["Whoop", "WHOOP", "whoop", "whoops", "Polar"]) },
            { pick([" ", " ", ", ", ":", "-", "'", "\u{2019}", ".", "_", "\n", "\t", "=", "(", ")", "#"]) },
            { pick(["e\u{301}", "\u{0}", "\u{1}", "\u{FFFD}", "\u{0600}", "\u{1F600}", "\u{200D}", "ẚ", "\u{FB00}",
                    "\u{212A}", "\u{FF21}", "—", "•", "…", "≥", "<device>", "<serial>", "<name>"]) },
            { pick(["Discovered", "Backfill:", "strap:", "payload=", "frame=", "[11:15:44]", "rr=", "4.0", "5.0"]) },
        ]
        return (0..<count).map { _ in
            (0..<(Int(next() % 24) + 1)).map { _ in pick(pieces)() }.joined()
        }
    }

    private static var corpus: [String] {
        let sample = strapLogSample
        return sample + sample.map(unmasked) + identifierShapes + [sleepSkippedLine]
            + fuzzLines(count: 4000, seed: 0x5EED_0F_0A1D)
    }

    // MARK: - Tests

    func testEveryCorpusLineRedactsByteForByteAsBefore() {
        var mismatches: [String] = []
        for line in Self.corpus {
            let expected = Self.legacyRedactPii(line)
            let actual = LiveState.redactPii(line)
            if Array(actual.utf8) != Array(expected.utf8) {
                mismatches.append("\(line.prefix(120).debugDescription)\n  old: \(expected.prefix(160).debugDescription)"
                                  + "\n  new: \(actual.prefix(160).debugDescription)")
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count) line(s) differ:\n" + mismatches.prefix(10).joined(separator: "\n"))
    }

    /// The corpus is only proof if the rules actually fire in it: each one has to have changed lines.
    func testTheCorpusExercisesEveryRule() {
        let changed = Self.corpus.map { (line: $0, out: Self.legacyRedactPii($0)) }.filter { $0.line != $0.out }
        for marker in ["••", "<serial>", "<device>", "<name>"] {
            XCTAssertTrue(changed.contains { $0.out.components(separatedBy: marker).count
                                             > $0.line.components(separatedBy: marker).count },
                          "no corpus line produced \(marker)")
        }
        let ids = Self.legacyRedactPii(Self.identifierShapes.joined(separator: "\n"))
        for masked in ["whoop-4C1…-noop", "whoop-4C1… ", "oura-ABC…-noop", "oura-ABC… "] {
            XCTAssertTrue(ids.contains(masked), "the id rules never produced \(masked)")
        }
        XCTAssertGreaterThan(changed.count, 100)
    }

    /// The byte gates skip a rule on a line without its stretch of ASCII bytes. That holds only if every
    /// character the case-insensitive hex class of the peripheral-id rule matches is ASCII: ICU folds case
    /// (Kelvin sign → k, long s → s), and one fold into a hex digit would let the regex match a line the
    /// gate had already skipped. Asked of every Unicode scalar at once.
    func testTheCaseInsensitiveHexClassMatchesOnlyAsciiHexDigits() throws {
        let re = try NSRegularExpression(pattern: "[0-9A-Fa-f]", options: [.caseInsensitive])
        var scalars = String.UnicodeScalarView()
        for v in UInt32(0)...0x10FFFF {
            guard let u = Unicode.Scalar(v) else { continue }
            scalars.append(u)
            scalars.append("|")
        }
        let all = String(scalars)
        let ns = all as NSString
        let hits = re.matches(in: all, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        XCTAssertEqual(hits.sorted(), "0123456789ABCDEFabcdef".map(String.init).sorted())
    }
}
