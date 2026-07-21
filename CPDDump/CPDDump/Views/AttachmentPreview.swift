import SwiftUI
import QuickLook

/// A downloaded evidence file ready for QuickLook.
struct PreviewFile: Identifiable {
    var id: URL { url }
    var url: URL
}

/// QuickLook wrapped for SwiftUI — previews PDFs, images and documents
/// downloaded through the authenticated API.
struct AttachmentQuickLook: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

/// Tappable evidence-file chips: live files download (with the bearer
/// token) and open in QuickLook; purged files show as honest stubs.
struct AttachmentChips: View {
    @Environment(Session.self) private var session

    var attachments: [AttachmentRef]
    @Binding var preview: PreviewFile?
    /// When set, live chips gain a ✕ that hands the file back for deletion.
    var onDelete: ((AttachmentRef) -> Void)?

    @State private var downloadingId: Int?
    @State private var errorMessage: String?

    var body: some View {
        if attachments.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                FlowLayout(spacing: 8) {
                    ForEach(attachments) { attachment in
                        chip(attachment)
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(PaperInk.sans(11, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private func chip(_ attachment: AttachmentRef) -> some View {
        if attachment.purged == true {
            HStack(spacing: 5) {
                Image(systemName: "doc.badge.ellipsis").font(.system(size: 11))
                Text(attachment.name ?? "File")
                    .strikethrough(true, color: PaperInk.stone400)
                Text("not kept").font(PaperInk.sans(10))
            }
            .font(PaperInk.sans(12))
            .foregroundStyle(PaperInk.stone400)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(
                Capsule().stroke(PaperInk.stone400.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            )
        } else {
            HStack(spacing: 5) {
                Button {
                    open(attachment)
                } label: {
                    HStack(spacing: 5) {
                        if downloadingId == attachment.id {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "paperclip").font(.system(size: 11))
                        }
                        Text(attachment.name ?? "File \(attachment.id)")
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(downloadingId != nil)

                if let onDelete {
                    Button {
                        onDelete(attachment)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(PaperInk.stone400)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(PaperInk.sans(12, weight: .semibold))
            .foregroundStyle(PaperInk.stone600)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.white)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(PaperInk.ink.opacity(0.25), lineWidth: 1.5))
        }
    }

    private func open(_ attachment: AttachmentRef) {
        downloadingId = attachment.id
        errorMessage = nil
        Task {
            defer { downloadingId = nil }
            do {
                let url = try await session.api.downloadAttachment(
                    id: attachment.id,
                    suggestedName: attachment.name
                )
                preview = PreviewFile(url: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
