#if DEBUG
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

extension DemoScreensV2 {
    /// Group 7 demo screens for `--demo-screen <name>` (lowercase names).
    static func group7(_ name: String) -> AnyView? {
        switch name {
        case "fused":         return AnyView(FusedRecordHost())
        // A multi-source fixture (the seeded demo store carries one strap only), so the provenance
        // chrome and the per-metric comparison can be captured.
        case "fused-multi":   return AnyView(FusedRecordView(record: G7DemoFixtures.fusedRecord, mergedAt: Date()))
        case "fused-steps":   return AnyView(FusedMetricDetailView(row: G7DemoFixtures.fusedRecord.rows[1]))
        case "applehealth":   return AnyView(AppleHealthView())
        case "applehealth-demo": return AnyView(G7AppleHealthDemoHost())
        case "miband":        return AnyView(XiaomiBandView())
        // The seeded demo store has no Mi Fitness import, so the populated page runs on a fixture.
        case "miband-demo":   return AnyView(XiaomiBandView(previewSeries: G7DemoFixtures.miSeries,
                                                            previewSleeps: G7DemoFixtures.miSleeps))
        case "datasources":   return AnyView(DataSourcesView())
        case "backup":        return AnyView(BackupSyncView())
        case "limitations":   return AnyView(NoopLimitationsView())
        case "storage":       return AnyView(StorageView())
        case "hownoopworks":  return AnyView(HowNoopWorksView(onClose: {}))
        default: return nil
        }
    }
}

/// Apple Health on the seeded preview series (built on the main actor, which the lookup is not).
private struct G7AppleHealthDemoHost: View {
    var body: some View { AppleHealthView.seededPreview() }
}

/// DEBUG-only fixtures for the group 7 demo screens, built through the real resolver.
enum G7DemoFixtures {
    private static func point(_ key: String, _ inputs: [(FusionSource, Double)]) -> FusedMetricPoint {
        FusionResolver.resolve(metricKey: key, inputs: inputs.map { FusionInput(source: $0.0, value: $0.1) })!
    }

    static var fusedRecord: FusedRecord {
        FusedRecord(
            rows: [
                FusedRow(point: point("rhr", [(.whoopImport, 52), (.appleHealth, 53)]), label: "Resting HR"),
                FusedRow(point: point("steps", [(.appleHealth, 8412), (.whoopImport, 7960), (.xiaomiBand, 6105)]),
                         label: "Steps"),
                FusedRow(point: point("sleep_total_min", [(.whoopImport, 432), (.appleHealth, 405)]), label: "Sleep"),
                FusedRow(point: point("skin_temp", [(.whoopImport, 0.3)]), label: "Skin temp"),
                FusedRow(point: point("hrv", [(.whoopImport, 68)]), label: "HRV"),
                FusedRow(point: point("spo2", [(.whoopImport, 96)]), label: "Blood oxygen"),
            ],
            dayOwner: .whoopImport,
            contributingSourceCount: 3
        )
    }

    /// 120 days of Mi Band series, shaped like an import (daily values, gently varying).
    static var miSeries: [String: [(day: String, value: Double)]] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        var out: [String: [(day: String, value: Double)]] = [:]
        for i in stride(from: 119, through: 0, by: -1) {
            let day = f.string(from: Date().addingTimeInterval(-Double(i) * 86_400))
            let p = Double(119 - i)
            func add(_ k: String, _ v: Double) { out[k, default: []].append((day, v)) }
            add("steps", 8_600 + 2_400 * sin(p / 5) + Double((Int(p) * 37) % 900))
            add("distance_m", 6_200 + 1_700 * sin(p / 5))
            add("energy_kcal", 420 + 140 * sin(p / 6 + 0.4))
            add("intensity_min", 34 + 18 * sin(p / 4))
            add("rhr", 55 + 3 * sin(p / 9))
            add("avg_hr", 68 + 4 * sin(p / 7))
            add("max_hr", 138 + 14 * sin(p / 5))
            add("spo2", 96.5 + 1.2 * sin(p / 4))
            add("sleep_total_min", 421 + 38 * sin(p / 6 + 1))
            add("sleep_deep_min", 78 + 14 * sin(p / 5))
            add("sleep_rem_min", 92 + 12 * sin(p / 7))
            add("sleep_light_min", 254 + 20 * sin(p / 6))
            add("sleep_score", 82 + 7 * sin(p / 6 + 1))
            add("stress", 31 + 9 * sin(p / 3))
            add("vitality", 72 + 6 * sin(p / 10))
        }
        return out
    }

    /// One imported night with a stage timeline (the importer's `[{start,end,stage}]` JSON).
    static var miSleeps: [CachedSleepSession] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = Int(today.timeIntervalSince1970) - 41 * 60     // 23:19 the evening before
        let plan: [(String, Int)] = [("wake", 9), ("light", 20), ("deep", 38), ("light", 23), ("rem", 14),
                                     ("light", 26), ("deep", 21), ("light", 26), ("wake", 3), ("light", 24),
                                     ("rem", 21), ("light", 32), ("rem", 18), ("light", 27), ("wake", 3),
                                     ("rem", 17), ("light", 15)]
        var t = start
        var segs: [String] = []
        for (stage, mins) in plan {
            segs.append("{\"start\":\(t),\"end\":\(t + mins * 60),\"stage\":\"\(stage)\"}")
            t += mins * 60
        }
        return [CachedSleepSession(startTs: start, endTs: t, efficiency: 94, restingHr: 55, avgHrv: nil,
                                   stagesJSON: "[" + segs.joined(separator: ",") + "]",
                                   deviceId: "xiaomi-band")]
    }
}
#endif
