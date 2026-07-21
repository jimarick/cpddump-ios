import SwiftUI

/// The little "i" beside any CPD points field — opens the shared
/// "Estimating CPD points" reference sheet.
struct CpdPointsInfoButton: View {
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(PaperInk.stone400)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Estimating CPD points")
        .sheet(isPresented: $showing) {
            CpdPointsInfoSheet()
                .presentationDetents([.medium, .large])
        }
    }
}

/// A compact reference for pricing an activity in points — a reference,
/// not a rule book.
struct CpdPointsInfoSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule()
                .fill(PaperInk.ink.opacity(0.2))
                .frame(width: 40, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)

            Text("Estimating CPD points").display(22)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    bullet("1 point ≈ 1 hour of active learning — the convention agreed across the UK royal colleges. Count the hours you were actually engaged, not the advertised maximum.")

                    bullet("Reflection can earn more. Most colleges award extra credit for documented reflection — typically 1 additional point per written reflective note (RCPath, RCOG), and the RCR invites additional credits for reflecting on the impact on your practice.")

                    bullet("Some activities have set values (they vary by college): a clinical audit or QI project up to ~5 points; a presentation or poster ~1–2; writing a journal article up to ~6; teaching often capped around 10–12 points a year.")

                    bullet("The year should add up to ~50 — the usual target is 50 points a year, 250 across the 5-year revalidation cycle.")

                    Text("Schemes differ in the fine print — when it matters, check your own college's CPD guidance. This is a reference, not a rule book.")
                        .font(PaperInk.sans(11))
                        .foregroundStyle(PaperInk.stone500)
                        .padding(.top, 4)
                }
                .padding(.bottom, 16)
            }
        }
        .padding(.horizontal, 20)
        .background(PaperInk.paper)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
                .font(PaperInk.sans(15, weight: .heavy))
                .foregroundStyle(PaperInk.brand)
            Text(text)
                .font(PaperInk.sans(13))
                .foregroundStyle(PaperInk.stone600)
        }
    }
}
