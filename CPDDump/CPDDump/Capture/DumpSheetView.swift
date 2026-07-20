import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// The in-app "Dump something" sheet: photos, documents, a link, or just
/// words. Every route lands in the same upload funnel.
struct DumpSheetView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    var onDumped: () -> Void

    enum Mode { case menu, link, words }

    /// Exact mirror of the server's upload allowlist
    /// (config/cpd.php → ingest.allowed_extensions) so the picker never
    /// offers a file the API will reject.
    static let pickerTypes: [UTType] = [
        "pdf", "jpg", "jpeg", "png", "webp", "heic", "heif", "gif",
        "tiff", "tif", "avif", "bmp",
        "doc", "docx", "ppt", "pptx", "txt", "ics",
        "eml", "csv", "xlsx", "xls", "md", "rtf", "mp3", "wav", "m4a",
    ].compactMap { UTType(filenameExtension: $0) }

    @State private var mode: Mode = .menu
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showDocumentPicker = false
    @State private var isPreparing = false

    // Link
    @State private var linkURL = ""
    @State private var linkNote = ""

    // Words
    @State private var title = ""
    @State private var details = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule()
                .fill(PaperInk.ink.opacity(0.2))
                .frame(width: 40, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)

            Text("Drop it on the pile").display(24)

            switch mode {
            case .menu: menu
            case .link: linkForm
            case .words: wordsForm
            }

            Text("Uploads in the background — the AI does the filing.")
                .font(PaperInk.sans(11))
                .foregroundStyle(PaperInk.stone500)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .background(PaperInk.paper)
        .fileImporter(
            isPresented: $showDocumentPicker,
            allowedContentTypes: Self.pickerTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                dumpDocuments(urls)
            }
        }
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            dumpPhotos(items)
        }
    }

    private var menu: some View {
        VStack(spacing: 10) {
            PhotosPicker(
                selection: $photoSelection,
                maxSelectionCount: 5,
                matching: .images
            ) {
                entryRow("Photos & screenshots", detail: "certificates, slides, whiteboards", symbol: "photo.on.rectangle")
            }
            .buttonStyle(.plain)

            Button { showDocumentPicker = true } label: {
                entryRow("A document", detail: "PDF, Word, slides, spreadsheets, audio", symbol: "doc")
            }
            .buttonStyle(.plain)

            Button { withAnimation(.snappy) { mode = .link } } label: {
                entryRow("Paste a link", detail: "an article, a course page", symbol: "link")
            }
            .buttonStyle(.plain)

            Button { withAnimation(.snappy) { mode = .words } } label: {
                entryRow("Just words", detail: "type what happened", symbol: "square.and.pencil")
            }
            .buttonStyle(.plain)

            if isPreparing {
                ProgressView("Preparing…")
                    .font(PaperInk.sans(12))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func entryRow(_ label: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(PaperInk.brandDark)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(PaperInk.sans(14, weight: .bold)).foregroundStyle(PaperInk.ink)
                Text(detail).font(PaperInk.sans(12)).foregroundStyle(PaperInk.stone500)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(PaperInk.stone400)
        }
        .padding(12)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(PaperInk.ink, lineWidth: 2))
        .stickerShadow()
    }

    private var linkForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                FieldLabel(text: "The link")
                TextField("https://…", text: $linkURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(PaperInk.sans(14))
                    .boxedField()
            }
            VStack(alignment: .leading, spacing: 4) {
                FieldLabel(text: "Anything the page doesn't say? (optional)")
                TextField("Why does it matter to you?", text: $linkNote, axis: .vertical)
                    .lineLimit(2 ... 5)
                    .font(PaperInk.sans(14))
                    .boxedField()
            }
            formButtons(dumpDisabled: normalisedURL == nil) {
                guard let url = normalisedURL else { return }
                UploadQueue.shared.enqueueLink(url, note: linkNote, session: session)
                finish()
            }
        }
    }

    private var wordsForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                FieldLabel(text: "What was it?")
                TextField("Taught the FY2s about sepsis", text: $title)
                    .font(PaperInk.sans(14))
                    .boxedField()
            }
            VStack(alignment: .leading, spacing: 4) {
                FieldLabel(text: "Details (optional)")
                TextField("Dates, what you did, what you took away…", text: $details, axis: .vertical)
                    .lineLimit(3 ... 8)
                    .font(PaperInk.sans(14))
                    .boxedField()
            }
            formButtons(dumpDisabled: title.trimmingCharacters(in: .whitespaces).isEmpty) {
                UploadQueue.shared.enqueueText(title: title, details: details, session: session)
                finish()
            }
        }
    }

    private func formButtons(dumpDisabled: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Button(action: action) {
                HStack(spacing: 7) {
                    Sparkle(size: 14, color: .white)
                    Text("Dump it")
                }
            }
            .buttonStyle(InkButtonStyle(prominent: true))
            .disabled(dumpDisabled)
            Button("Back") { withAnimation(.snappy) { mode = .menu } }
                .font(PaperInk.sans(13, weight: .semibold))
                .foregroundStyle(PaperInk.stone500)
        }
        .padding(.top, 4)
    }

    private var normalisedURL: String? {
        var candidate = linkURL.trimmingCharacters(in: .whitespaces)
        guard !candidate.isEmpty else { return nil }
        if !candidate.contains("://") { candidate = "https://" + candidate }
        guard let url = URL(string: candidate), url.host() != nil else { return nil }
        return candidate
    }

    // MARK: Loading pickers into the queue

    private func dumpPhotos(_ items: [PhotosPickerItem]) {
        isPreparing = true
        Task {
            var files: [(data: Data, filename: String, mimeType: String)] = []
            for (index, item) in items.enumerated() {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let type = item.supportedContentTypes.first
                let ext = type?.preferredFilenameExtension ?? "jpg"
                let mime = type?.preferredMIMEType ?? "image/jpeg"
                files.append((data, "photo-\(index + 1).\(ext)", mime))
            }
            if !files.isEmpty {
                UploadQueue.shared.enqueueFiles(files, session: session)
                finish()
            } else {
                isPreparing = false
            }
        }
    }

    private func dumpDocuments(_ urls: [URL]) {
        var files: [(data: Data, filename: String, mimeType: String)] = []
        for url in urls.prefix(5) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            files.append((data, url.lastPathComponent, mime))
        }
        if !files.isEmpty {
            UploadQueue.shared.enqueueFiles(files, session: session)
            finish()
        }
    }

    private func finish() {
        onDumped()
        dismiss()
    }
}

private extension View {
    func boxedField() -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PaperInk.ink.opacity(0.35), lineWidth: 1.5))
    }
}
