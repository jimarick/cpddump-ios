import SwiftUI

/// Push preferences, behind the avatar menu: the daily morning gem and the
/// weekly nudge. Each flip PATCHes user/preferences immediately; the server
/// answers with the full fresh user payload, which the session adopts.
struct SettingsSheetView: View {
    @Environment(Session.self) private var session

    @State private var morningGem = false
    @State private var weeklyNudge = false
    /// Guards the onChange handlers while the toggles are being seeded
    /// (or reverted after a failed save).
    @State private var seeded = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule()
                .fill(PaperInk.ink.opacity(0.2))
                .frame(width: 40, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)

            Text("Settings").display(24)

            FieldLabel(text: "Notifications")

            toggleRow(
                "Morning gem",
                detail: "one nugget from your own pile, each morning",
                isOn: $morningGem
            )

            toggleRow(
                "Weekly nudge",
                detail: "a once-a-week reminder to keep the pile moving",
                isOn: $weeklyNudge
            )

            if let errorMessage {
                Text(errorMessage)
                    .font(PaperInk.sans(12, weight: .semibold))
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .background(PaperInk.paper)
        .onAppear {
            morningGem = session.user?.pushMorningGemEnabled ?? false
            weeklyNudge = session.user?.pushWeeklyNudgeEnabled ?? false
            seeded = true
        }
        .onChange(of: morningGem) { save() }
        .onChange(of: weeklyNudge) { save() }
    }

    private func toggleRow(_ label: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(PaperInk.sans(14, weight: .bold)).foregroundStyle(PaperInk.ink)
                Text(detail).font(PaperInk.sans(12)).foregroundStyle(PaperInk.stone500)
            }
        }
        .tint(PaperInk.brand)
        .padding(12)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(PaperInk.ink, lineWidth: 2))
        .stickerShadow()
    }

    private func save() {
        guard seeded else { return }
        let gem = morningGem
        let nudge = weeklyNudge
        Task {
            do {
                let fresh = try await session.api.updatePreferences(weeklyNudge: nudge, morningGem: gem)
                session.updateUser(fresh)
                errorMessage = nil
                // Make sure a device token is registered for the push to land on.
                if gem || nudge {
                    NotificationManager.shared.registerIfAuthorized()
                }
            } catch {
                errorMessage = error.localizedDescription
                // Roll the switches back to what the server still believes.
                seeded = false
                morningGem = session.user?.pushMorningGemEnabled ?? false
                weeklyNudge = session.user?.pushWeeklyNudgeEnabled ?? false
                seeded = true
            }
        }
    }
}
