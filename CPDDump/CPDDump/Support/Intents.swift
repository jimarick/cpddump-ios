import AppIntents
import Observation

/// Cross-launch signals from App Intents into the UI: an intent sets a flag,
/// the tab view consumes it once presented.
@Observable
final class LaunchActions {
    static let shared = LaunchActions()

    var wantsRecorder = false
    var wantsInbox = false
    /// Set when a push notification deep-links to a specific inbox item.
    var reviewItemId: Int?
    /// Set when a push (e.g. the morning gem) deep-links to an approved activity.
    var openActivityId: Int?
}

/// "Dump a voice note" — recording starts before the app is even visible.
/// Reachable from Siri, Shortcuts, Spotlight, and the Action button.
struct DumpVoiceNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Dump a voice note"
    static let description = IntentDescription(
        "Start recording straight into the pile — the AI does the filing."
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchActions.shared.wantsRecorder = true
        return .result()
    }
}

struct CPDDumpShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DumpVoiceNoteIntent(),
            phrases: [
                "Dump a voice note with \(.applicationName)",
                "Record a voice note in \(.applicationName)",
                "Dump it to \(.applicationName)",
            ],
            shortTitle: "Dump a voice note",
            systemImageName: "mic.fill"
        )
    }
}
