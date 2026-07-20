import SwiftUI

/// One file offered for keeping at save time.
struct ConfirmFile: Identifiable {
    var id: Int
    var name: String
    /// Source entry title, shown as `from "…"` in the merge flow.
    var from: String?
}

/// A sensitive-info flag shown in the confirm step.
struct SensitiveFlag {
    var type: String
    var excerpt: String?
}

/// The web's "Before this is saved" popup, native: the sensitive-info
/// warning and the keep-or-delete files decision live together here, so
/// the forms themselves carry no warning banners. Proceeding past a shown
/// warning sends the PII ack — the server gate still enforces it.
struct ApproveConfirmSheet: View {
    var files: [ConfirmFile]
    var flags: [SensitiveFlag]
    /// Where the flagged content lives; defaults to files-vs-text wording.
    var flagLocation: String?
    var verb: String
    var isWorking: Bool
    var onConfirm: (_ keepIds: [Int], _ piiAck: Bool) -> Void
    /// Text-only flag path: scrub the typed text server-side, then submit.
    var onRemoveInfo: (() -> Void)?
    var onCancel: () -> Void

    @State private var keepIds: Set<Int> = []

    private var hasFlags: Bool { !flags.isEmpty }
    private var hasFiles: Bool { !files.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule()
                .fill(PaperInk.ink.opacity(0.2))
                .frame(width: 40, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)

            Text("Before this is saved").display(22)

            if hasFlags {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Possible sensitive info", systemImage: "exclamationmark.triangle.fill")
                        .font(PaperInk.sans(13, weight: .heavy))
                        .foregroundStyle(PaperInk.brandDark)

                    Text(flagSummary)
                        .font(PaperInk.sans(12.5))
                        .foregroundStyle(PaperInk.stone600)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PaperInk.tint.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(PaperInk.brand, lineWidth: 2))
            }

            if hasFiles {
                Text(hasFlags
                    ? "Unticked files are deleted — your written entry is kept either way. Keeping a file records that you've checked it contains nothing identifiable."
                    : "Unticked files are deleted — your written entry is kept either way. Only keep a file you're sure contains nothing identifiable.")
                    .font(PaperInk.sans(12))
                    .foregroundStyle(PaperInk.stone500)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(files) { file in
                        Button {
                            if keepIds.contains(file.id) { keepIds.remove(file.id) } else { keepIds.insert(file.id) }
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: keepIds.contains(file.id) ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 16))
                                    .foregroundStyle(keepIds.contains(file.id) ? PaperInk.brand : PaperInk.stone400)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.name)
                                        .font(PaperInk.sans(13, weight: .semibold))
                                        .lineLimit(1)
                                    if let from = file.from {
                                        Text("from “\(from)”")
                                            .font(PaperInk.sans(11))
                                            .foregroundStyle(PaperInk.stone400)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                if hasFiles {
                    Button(isWorking ? "Saving…" : "\(verb) & delete files") {
                        onConfirm([], hasFlags)
                    }
                    .buttonStyle(InkButtonStyle(prominent: true))
                    .disabled(isWorking)

                    Button("Keep selected & \(verb.lowercased())") {
                        onConfirm(Array(keepIds), hasFlags)
                    }
                    .buttonStyle(InkButtonStyle())
                    .disabled(isWorking || keepIds.isEmpty)
                } else {
                    if let onRemoveInfo {
                        Button(isWorking ? "Saving…" : "Remove sensitive info & \(verb.lowercased())") {
                            onRemoveInfo()
                        }
                        .buttonStyle(InkButtonStyle(prominent: true))
                        .disabled(isWorking)
                    }

                    Button("\(verb) — I've checked it") {
                        onConfirm([], true)
                    }
                    .buttonStyle(InkButtonStyle())
                    .disabled(isWorking)
                }

                Button("Back") { onCancel() }
                    .font(PaperInk.sans(13, weight: .bold))
                    .foregroundStyle(PaperInk.stone500)
                    .disabled(isWorking)
            }
            .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .background(.white)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    private var flagSummary: String {
        let list = flags
            .map { flag in
                flag.type.replacingOccurrences(of: "_", with: " ")
                    + (flag.excerpt.map { " “\($0)”" } ?? "")
            }
            .joined(separator: " · ")
        let location = flagLocation ?? (hasFiles ? "the files below" : "your text")

        return "\(list) — in \(location)."
    }
}
