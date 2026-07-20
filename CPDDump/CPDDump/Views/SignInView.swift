import SwiftUI

struct SignInView: View {
    @Environment(Session.self) private var session

    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var needsCode = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showServerField = false

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                Spacer(minLength: 60)

                Wordmark(size: 34)

                VStack(spacing: 4) {
                    Text("Sign in").display(36)
                    Text("dump it from your pocket")
                        .font(PaperInk.hand(22))
                        .foregroundStyle(PaperInk.brandDark)
                        .tilt(-1.5)
                }

                VStack(alignment: .leading, spacing: 14) {
                    field("Email") {
                        TextField("you@example.com", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    field("Password") {
                        SecureField("••••••••", text: $password)
                            .textContentType(.password)
                    }

                    if needsCode {
                        field("Two-factor code") {
                            TextField("123456", text: $code)
                                .keyboardType(.numberPad)
                                .textContentType(.oneTimeCode)
                        }
                    }

                    if showServerField {
                        field("Server") {
                            TextField("https://cpd-dump.test", text: serverBinding)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(PaperInk.sans(13, weight: .semibold))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    submit()
                } label: {
                    HStack(spacing: 8) {
                        if isWorking { ProgressView().tint(.white) }
                        Text(isWorking ? "Signing in…" : "Sign in")
                    }
                }
                .buttonStyle(InkButtonStyle(prominent: true))
                .disabled(isWorking || email.isEmpty || password.isEmpty)

                #if DEBUG
                Button("Server settings") {
                    withAnimation { showServerField.toggle() }
                }
                .font(PaperInk.sans(12, weight: .semibold))
                .foregroundStyle(PaperInk.stone500)
                #endif

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(PaperInk.paper)
    }

    private var serverBinding: Binding<String> {
        Binding(
            get: { session.serverURLString },
            set: { session.serverURLString = $0 }
        )
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(text: label)
            content()
                .font(PaperInk.sans(15))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PaperInk.ink.opacity(0.35), lineWidth: 1.5))
        }
    }

    private func submit() {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await session.signIn(email: email, password: password, code: code.isEmpty ? nil : code)
            } catch let error as APIError where error.needsTwoFactorCode && !needsCode {
                withAnimation { needsCode = true }
                errorMessage = "Enter your two-factor code to finish signing in."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
