import SwiftUI
import StrandDesign

/// Official-app-style guided arm dialog. Shows connect → set clock → write → confirm as a live
/// checklist, then a success ("buzzes even with NOOP closed") or failure ("phone backup is still
/// set") footer. Driven entirely by `AlarmArmCoordinator.step`.
struct ArmAlarmSheet: View {
    @ObservedObject var coordinator: AlarmArmCoordinator
    let onDone: () -> Void
    let onRetry: () -> Void

    private struct Phase: Identifiable { let id: Int; let label: String; let order: Int }
    private let phases: [Phase] = [
        .init(id: 0, label: "Connecting to your strap", order: 0),
        .init(id: 1, label: "Setting the strap clock", order: 1),
        .init(id: 2, label: "Writing the alarm", order: 2),
        .init(id: 3, label: "Confirming it stored", order: 3),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Arming your strap alarm")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(phases) { phase in
                    HStack(spacing: 12) {
                        statusIcon(for: phase.order)
                        Text(phase.label)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                    }
                }
            }

            footer
        }
        .padding(24)
        .frame(minWidth: 320)
        .interactiveDismissDisabled(isBusy)
    }

    private var currentOrder: Int {
        switch coordinator.step {
        case .idle, .connecting: return 0
        case .syncingClock: return 1
        case .writing: return 2
        case .confirming: return 3
        case .confirmed: return 4
        case .failed: return -1
        }
    }

    private var isBusy: Bool {
        switch coordinator.step {
        case .confirmed, .failed: return false
        default: return true
        }
    }

    /// The cutoff below which earlier rows show a checkmark. On failure this is the failed phase
    /// (so phases that completed before the failure keep their checkmarks); otherwise it tracks the
    /// active phase. `currentOrder` is -1 in `.failed`, which would wrongly demote completed rows to
    /// pending dots, so the failure case must key off `failedAtOrder` here.
    private var completedOrder: Int {
        if case .failed = coordinator.step { return failedAtOrder }
        return currentOrder
    }

    @ViewBuilder
    private func statusIcon(for order: Int) -> some View {
        if case .failed = coordinator.step, order >= failedAtOrder {
            Image(systemName: "xmark.circle.fill").foregroundStyle(StrandPalette.statusWarning)
        } else if order < completedOrder {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(StrandPalette.accent)
        } else if order == currentOrder {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "circle").foregroundStyle(StrandPalette.textSecondary.opacity(0.4))
        }
    }

    /// Which phase the failure occurred at (so earlier phases keep their checkmarks).
    private var failedAtOrder: Int {
        guard case let .failed(reason) = coordinator.step else { return Int.max }
        switch reason {
        case .noLink, .cancelled: return 0
        case .notStored: return 3
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch coordinator.step {
        case let .confirmed(epoch):
            VStack(alignment: .leading, spacing: 8) {
                Text("Confirmed for \(Self.clock.string(from: Date(timeIntervalSince1970: TimeInterval(epoch))))")
                    .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Text("Your strap will buzz your wrist even with NOOP closed.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                Button("Done", action: onDone).buttonStyle(.borderedProminent)
            }
        case let .failed(reason):
            VStack(alignment: .leading, spacing: 8) {
                Text(message(for: reason))
                    .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Text("Your phone backup alarm is still set, so you'll still be woken.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                HStack {
                    Button("Retry", action: onRetry).buttonStyle(.borderedProminent)
                    Button("Keep my phone alarm", action: onDone)
                }
            }
        default:
            HStack {
                Spacer()
                Button("Cancel") { coordinator.cancel() }
            }
        }
    }

    private func message(for reason: ArmFailure) -> String {
        switch reason {
        case .noLink: return "Couldn't reach your strap."
        case .notStored: return "Your strap didn't store the alarm."
        case .cancelled: return "Arming cancelled."
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f
    }()
}
