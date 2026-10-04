import SwiftUI
import StrandDesign

extension TodaySection {
    /// The Phosphor glyph for the editor row.
    var customizationIcon: String {
        switch self {
        case .hero: return "gauge"
        case .liveSession: return "play-circle"
        case .synthesis: return "sparkle"
        case .keyMetrics: return "squares-four"
        case .workouts: return "person-simple-run"
        case .heartRate: return "heartbeat"
        case .recoveryVitals: return "heart"
        case .yourCards: return "cards"
        case .menstrualCycle: return "drop-half"
        case .journal: return "notebook"
        case .addedCards: return "plus-square"
        }
    }

    /// The v2 editor label. `title` stays the stored, Android-shared label; this is what the Customize
    /// sheet shows, named the way the Today screen titles each block.
    var customizationTitle: String {
        switch self {
        case .hero: return String(localized: "Scores")
        case .liveSession: return String(localized: "Start session")
        case .synthesis: return String(localized: "Synthesis")
        case .keyMetrics: return String(localized: "Key metrics")
        case .workouts: return String(localized: "Last workouts")
        case .heartRate: return String(localized: "Heart rate · Live")
        case .recoveryVitals: return String(localized: "Recovery vitals")
        case .yourCards: return String(localized: "Your cards")
        case .menstrualCycle: return String(localized: "Menstrual cycle")
        case .journal: return String(localized: "Journal")
        case .addedCards: return String(localized: "Added cards")
        }
    }

    /// What the block shows, for the editor row's caption. nil where the sheet supplies a live count.
    var customizationCaption: String? {
        switch self {
        case .hero: return String(localized: "Charge · Effort · Rest")
        case .liveSession: return String(localized: "Silent strap coaching against today's Charge")
        case .synthesis: return String(localized: "Your day in one sentence")
        case .workouts: return String(localized: "The two most recent, with the total")
        case .heartRate: return String(localized: "Streams while the strap is in range")
        case .recoveryVitals: return String(localized: "HRV · resting HR · respiration")
        case .menstrualCycle: return String(localized: "Phase and next period estimate")
        case .journal: return String(localized: "Weekly check-in strip")
        case .keyMetrics, .yourCards, .addedCards: return nil
        }
    }

    var customizationTint: Color {
        switch self {
        case .hero: return StrandPalette.chargeColor
        case .liveSession: return StrandPalette.metricCyan
        case .synthesis: return StrandPalette.accent
        case .keyMetrics: return StrandPalette.metricPurple
        case .workouts: return StrandPalette.effortColor
        case .heartRate: return StrandPalette.metricRose
        case .recoveryVitals: return StrandPalette.metricCyan
        case .yourCards: return StrandPalette.accent
        case .menstrualCycle: return StrandPalette.restColor
        case .journal: return StrandPalette.metricAmber
        case .addedCards: return StrandPalette.accent
        }
    }
}

extension KeyMetric {
    /// The Phosphor glyph for the editor row — the same one the Today tile draws.
    var customizationIcon: String { phIcon }

    var customizationTint: Color {
        switch self {
        case .charge: return StrandPalette.chargeColor
        case .effort: return StrandPalette.effortColor
        case .rest, .hrv: return StrandPalette.metricPurple
        case .restingHr: return StrandPalette.metricRose
        case .bloodOxygen, .steps: return StrandPalette.metricCyan
        case .respiratory, .weight: return StrandPalette.accent
        case .calories, .skinTemp: return StrandPalette.metricAmber
        }
    }
}

extension DashboardCard {
    var customizationTint: Color {
        switch self {
        case .stress, .respiratory: return StrandPalette.accent
        case .fitnessAge: return StrandPalette.chargeColor
        case .vo2max: return StrandPalette.chargeColor
        case .vitality, .hrv: return StrandPalette.metricPurple
        case .restingHr: return StrandPalette.metricRose
        case .steps, .stepsAverage30, .bloodOxygen, .hydration: return StrandPalette.metricCyan
        case .skinTemp, .calories: return StrandPalette.metricAmber
        case .sleep: return StrandPalette.restColor
        case .coupled: return StrandPalette.chargeColor
        case .coach: return StrandPalette.accent
        }
    }
}
