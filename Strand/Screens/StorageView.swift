import SwiftUI
import StrandDesign

/// #590 — on-device storage diagnostics. iOS users saw "Documents & Data" balloon to ~19 GB after an
/// Apple Health import: the document picker's `asCopy:true` duplicate sat in `Documents/Inbox/` forever
/// and the WAL never truncated. AppModel now reclaims both automatically (Inbox cleanup on import +
/// launch, WAL truncate after each import); this screen makes the footprint VISIBLE and gives a manual
/// "Clean up now" escape hatch for anyone who already grew a backlog before the fix shipped.
///
/// Read-only otherwise: it shows the database size, the leftover Inbox size, and any stranded import
/// temp files. The button purges Inbox + temp and truncates the WAL — never touches live rows.
struct StorageView: View {
    @EnvironmentObject var model: AppModel

    @State private var report: AppModel.StorageReport?
    @State private var loading = true
    @State private var cleaning = false
    @State private var lastCleanedSummary: String?
    /// The volume's total capacity, for the hero's "share of this device" caption; nil when unreadable.
    @State private var volumeBytes: Int64?

    var body: some View {
        ScreenScaffold(title: nil) {
            NoopScreenHeader("Storage")
                .padding(.bottom, 6)
            if loading && report == nil {
                NoopCard {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small).tint(StrandPalette.textSecondary)
                        Text("Measuring…")
                            .font(StrandFont.light(14, relativeTo: .subheadline))
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer(minLength: 0)
                    }
                }
            } else if let report {
                hero(report)
                NoopSectionTitle("What takes space", caption: Self.format(total(report)))
                breakdownList(report)
                cleanUp(report)
            } else {
                NoopCard {
                    VStack(alignment: .leading, spacing: 10) {
                        NoopCardHeader("Storage unavailable", icon: "hard-drives")
                        Text("Couldn't read the local store right now. Try again in a moment.")
                            .font(StrandFont.light(14, relativeTo: .subheadline))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            explainerCard
            Text("Nothing is uploaded. This is all on \(Platform.deviceNounPhrase).")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
        }
        .noopHidesSystemNavBar()
        .task { await load() }
    }

    // MARK: - Hero

    /// One category of the footprint: its share of the bar, its swatch, and how it reads.
    private struct Part: Identifiable {
        let id: String
        let label: LocalizedStringKey
        let caption: LocalizedStringKey
        let bytes: Int64
        let swatch: Color
    }

    private func parts(_ r: AppModel.StorageReport) -> [Part] {
        [
            Part(id: "db", label: "Health database",
                 caption: "Every reading NOOP keeps, in one file",
                 bytes: r.db ?? 0, swatch: StrandPalette.metricCyan),
            Part(id: "inbox", label: "Leftover import copies",
                 caption: r.inbox > 0 ? "Reclaimable" : "Nothing left behind",
                 bytes: r.inbox, swatch: StrandPalette.textPrimary.opacity(0.8)),
            Part(id: "temp", label: "Import temp files",
                 caption: r.importTemp > 0 ? "Reclaimable" : "Nothing left behind",
                 bytes: r.importTemp, swatch: StrandPalette.textPrimary.opacity(0.45)),
        ]
    }

    private func total(_ r: AppModel.StorageReport) -> Int64 { (r.db ?? 0) + r.inbox + r.importTemp }

    /// The ink hero: the whole footprint as one number, and a stacked bar of what it is made of.
    private func hero(_ r: AppModel.StorageReport) -> some View {
        let sum = total(r)
        let figure = Self.split(Self.format(sum))
        return NoopHeroCard(glow: .ink, padding: 22) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    NoopIconBadge(verbatim: String(localized: "On \(Platform.deviceNounPhrase)"), icon: "hard-drives")
                    Spacer(minLength: 8)
                    if model.repo.days.count > 0 {
                        NoopPill(verbatim: String(localized: "\(model.repo.days.count) days"), compact: true)
                    }
                }
                NoopDotNumber(figure.number, unit: figure.unit, size: 92, unitSize: 30)
                    .padding(.top, 30)
                Text("Everything NOOP keeps on \(Platform.deviceNounPhrase).")
                    .font(StrandFont.light(19, relativeTo: .title3))
                    .tracking(-0.2)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
                stackedBar(parts(r), total: sum)
                    .frame(height: 16)
                    .padding(.top, 22)
                HStack {
                    if sum > 0 {
                        Text("Database \(Self.percent(r.db ?? 0, of: sum))")
                    }
                    Spacer(minLength: 8)
                    if let volumeBytes, volumeBytes > 0 {
                        Text("\(Self.percent(sum, of: volumeBytes, decimals: 1)) of \(Self.format(volumeBytes))")
                    }
                }
                .font(StrandFont.light(10.5, relativeTo: .caption2))
                .foregroundStyle(StrandPalette.textSecondary)
                .padding(.top, 10)
            }
            .padding(.bottom, 2)
        }
    }

    /// Rounded segments, one per category, each at least a sliver wide so a tiny one still shows.
    private func stackedBar(_ parts: [Part], total: Int64) -> some View {
        GeometryReader { geo in
            let shown = parts.filter { $0.bytes > 0 }
            let gaps = CGFloat(max(shown.count - 1, 0)) * 3
            let width = max(geo.size.width - gaps, 0)
            HStack(spacing: 3) {
                ForEach(shown) { part in
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(part.swatch)
                        .frame(width: max(18, width * CGFloat(Double(part.bytes) / Double(max(total, 1)))))
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Breakdown + clean-up

    private func breakdownList(_ r: AppModel.StorageReport) -> some View {
        let sum = total(r)
        return NoopList {
            ForEach(parts(r)) { part in
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(part.swatch)
                        .frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(part.label)
                            .font(StrandFont.book(15, relativeTo: .body))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(part.caption)
                            .font(StrandFont.light(12, relativeTo: .caption))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(part.id == "db" && r.db == nil ? "—" : Self.format(part.bytes))
                            .font(StrandFont.value(15))
                            .foregroundStyle(StrandPalette.textPrimary)
                        if sum > 0 {
                            Text(Self.percent(part.bytes, of: sum))
                                .font(StrandFont.light(11, relativeTo: .caption2))
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 15)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func cleanUp(_ r: AppModel.StorageReport) -> some View {
        let reclaimable = r.inbox + r.importTemp
        return VStack(alignment: .leading, spacing: 10) {
            NoopButton(cleaning ? "Cleaning up…" : "Clean up now", kind: .primary, fullWidth: true) {
                Task { await cleanUp() }
            }
            .disabled(cleaning || reclaimable == 0)
            .accessibilityLabel("Clean up leftover import files")
            Text(reclaimable > 0
                 ? "There's about \(Self.format(reclaimable)) of leftover import scratch space to reclaim. This never removes your imported data."
                 : "Nothing to reclaim right now. NOOP already cleans up import scratch space automatically.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 6)
            if let lastCleanedSummary {
                Text(lastCleanedSummary)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 12)
    }

    private var explainerCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                NoopCardHeader("Why does this grow?", icon: "question")
                Text("When you import an Apple Health or WHOOP export, iOS hands NOOP a private copy of the file. NOOP reads it, saves your data into the health database, then deletes the copy. Older builds didn't delete every copy. This screen reclaims any that were left behind.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 12)
    }

    // MARK: - Data

    private func load() async {
        loading = true
        let r = await model.storageReport()
        report = r
        let home = URL(fileURLWithPath: NSHomeDirectory())
        volumeBytes = (try? home.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity.map(Int64.init)
        loading = false
    }

    private func cleanUp() async {
        guard !cleaning else { return }
        cleaning = true
        let before = (report?.inbox ?? 0) + (report?.importTemp ?? 0)
        let r = await model.cleanUpStorage()
        let after = r.inbox + r.importTemp
        let freed = max(0, before - after)
        report = r
        lastCleanedSummary = freed > 0 ? String(localized: "Reclaimed \(Self.format(freed)).") : String(localized: "Already clean.")
        cleaning = false
    }

    /// Human byte size, decimal (matches iOS Settings' "Documents & Data" presentation).
    static func format(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.allowsNonnumericFormatting = false   // "0 KB", not "Zero KB", beside real figures
        return f
    }()

    /// "412 MB" → ("412", "MB") so the unit can set small beside the hero figure.
    private static func split(_ s: String) -> (number: String, unit: String?) {
        guard let space = s.lastIndex(where: { $0 == " " || $0 == "\u{00A0}" }) else { return (s, nil) }
        return (String(s[..<space]), String(s[s.index(after: space)...]))
    }

    private static func percent(_ part: Int64, of whole: Int64, decimals: Int = 0) -> String {
        guard whole > 0 else { return "—" }
        return (Double(part) / Double(whole)).formatted(.percent.precision(.fractionLength(decimals)))
    }
}
