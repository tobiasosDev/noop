import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Performance Report — periodized 7/28-day assessment (recovery / sleep / strain
/// + takeaways), computed on-device by PerformanceReport from the dashboard cache.
struct ReportView: View {
    @EnvironmentObject private var repo: Repository
    @State private var period: PerformanceReport.Period = .weekly

    private var summary: PerformanceReport.Summary {
        PerformanceReport.build(days: repo.days, period: period,
                                today: Repository.localDayKey(Date()))
    }

    var body: some View {
        ScreenScaffold(title: "Performance Report",
                       subtitle: "Your recovery, sleep and strain over the period — and what to do next.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                SegmentedPillControl(PerformanceReport.Period.allCases,
                                     selection: $period,
                                     label: { $0 == .weekly ? String(localized: "Weekly") : String(localized: "Monthly") })
                let s = summary
                if s.coverage == 0 {
                    ComingSoon(what: "No data in this period yet. Wear the strap or import your WHOOP export in Data Sources, then check back.")
                } else {
                    headerCard(s)
                    if !s.takeaways.isEmpty { takeawaysSection(s) }
                    recoverySection(s)
                    sleepSection(s)
                    strainSection(s)
                }
            }
        }
    }

    // MARK: Header

    private func headerCard(_ s: PerformanceReport.Summary) -> some View {
        NoopCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "\(s.fromDay) → \(s.toDay)")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("\(s.coverage) of \(s.period.days) days with data")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
            }
        }
    }

    // MARK: Takeaways

    private func takeawaysSection(_ s: PerformanceReport.Summary) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Takeaways", overline: "What the period says")
            NoopCard {
                VStack(alignment: .leading, spacing: 8) {
                    // PerformanceReport emits structured facts; the sentences live here
                    // as LocalizedStringKeys so every takeaway ships through the catalog.
                    ForEach(s.takeaways, id: \.self) { t in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(StrandPalette.accent).frame(width: 7, height: 7)
                                .padding(.top, 5)
                            takeawayText(t).font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func takeawayText(_ t: PerformanceReport.Takeaway) -> some View {
        switch t {
        case .overreach(let days):
            Text("\(days) days above your strain target — watch recovery.")
        case .hrvUp:
            Text("HRV trending up — adaptation is going well.")
        case .hrvDown:
            Text("HRV trending down — consider easing off.")
        case .recoveryUp(let p):
            Text("Recovery up \(p, specifier: "%.0f")% vs the prior period.")
        case .recoveryDown(let p):
            Text("Recovery down \(p, specifier: "%.0f")% vs the prior period.")
        case .lowSleepPerformance(let p):
            Text("Averaging only \(p, specifier: "%.0f")% of your sleep need.")
        }
    }

    // MARK: Sections — shared tile builders

    /// Δ caption like "+4.2 vs prior" — hidden (nil) when no prior-window data.
    /// The signed number is non-linguistic; only "vs prior" goes through the catalog.
    private func deltaCaption(_ a: PerformanceReport.Average?, unit: String, decimals: Int) -> String? {
        guard let d = a?.delta else { return nil }
        let amount = String(format: "%+.\(decimals)f%@", d, unit)
        return String(localized: "\(amount) vs prior")
    }

    private func tile(_ label: LocalizedStringKey, _ a: PerformanceReport.Average?,
                      unit: String, decimals: Int) -> some View {
        StatTile(label: label,
                 value: a.map { String(format: "%.\(decimals)f%@", $0.value, unit) } ?? "—",
                 caption: deltaCaption(a, unit: unit, decimals: decimals))
    }

    private var grid: [GridItem] { [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)] }

    private func recoverySection(_ s: PerformanceReport.Summary) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Recovery", overline: "Capacity over the period")
            LazyVGrid(columns: grid, spacing: NoopMetrics.gap) {
                tile("Avg recovery", s.recovery, unit: "%", decimals: 0)
                tile("Avg HRV", s.hrv, unit: " ms", decimals: 0)
                tile("Avg RHR", s.rhr, unit: " bpm", decimals: 0)
                if let b = s.bestRecoveryDay {
                    StatTile(label: "Best day", value: String(format: "%.0f%%", b.value), caption: b.day)
                }
                if let w = s.worstRecoveryDay {
                    StatTile(label: "Toughest day", value: String(format: "%.0f%%", w.value), caption: w.day)
                }
            }
        }
    }

    private func sleepSection(_ s: PerformanceReport.Summary) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep", overline: "Need vs banked")
            LazyVGrid(columns: grid, spacing: NoopMetrics.gap) {
                StatTile(label: "Avg sleep",
                         value: s.sleepMin.map { hoursText($0.value) } ?? "—",
                         caption: s.sleepMin?.delta.map { sleepDeltaCaption($0) })
                StatTile(label: "Sleep need", value: hoursText(s.sleepNeedMin), caption: nil)
                StatTile(label: "Performance",
                         value: s.sleepPerformancePct.map { String(format: "%.0f%%", $0) } ?? "—",
                         caption: String(localized: "of need banked"))
            }
        }
    }

    private func sleepDeltaCaption(_ delta: Double) -> String {
        let amount = String(format: "%+.0f", delta)
        return String(localized: "\(amount) min vs prior")
    }

    private func strainSection(_ s: PerformanceReport.Summary) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Strain", overline: "Load vs your targets")
            LazyVGrid(columns: grid, spacing: NoopMetrics.gap) {
                tile("Avg strain", s.strain, unit: "", decimals: 1)
                StatTile(label: "Total strain",
                         value: s.totalStrain.map { String(format: "%.1f", $0) } ?? "—",
                         caption: nil)
                StatTile(label: "Over target",
                         value: dayCount(s.overreachDays),
                         caption: String(localized: "above the recovery-set band"))
                StatTile(label: "Under target",
                         value: dayCount(s.underreachDays),
                         caption: String(localized: "room left on the table"))
            }
        }
    }

    /// Pluralized day count — separate singular/plural catalog keys so German
    /// (and any future language) can translate both forms.
    private func dayCount(_ n: Int) -> String {
        n == 1 ? String(localized: "1 day") : String(localized: "\(n) days")
    }

    private func hoursText(_ minutes: Double) -> String {
        let h = Int(minutes) / 60, m = Int(minutes) % 60
        return "\(h)h \(String(format: "%02d", m))m"
    }
}
