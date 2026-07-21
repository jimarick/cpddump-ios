import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// The in-app "Dump something" sheet: photos, documents, a link, or just
/// words. Every route lands in the same upload funnel.
struct DumpSheetView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    var onDumped: () -> Void

    enum Mode { case menu, link, debrief, voice }

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

    // Debrief (also covers the old "just words" — a title alone is enough)
    @State private var debriefTitle = ""
    @State private var debriefDate: Date = .now
    @State private var debriefNotes = ""
    @State private var debriefURL = ""

    // Voice note (text-first: the transcript lands here as editable words)
    @State private var voiceText = ""

    // Shared dictation plumbing — only one form is ever visible at a time.
    @State private var recorder = DictationRecorder()
    @State private var transcribing = false
    @State private var dictationError: String?

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
            case .debrief: ScrollView { debriefForm }.scrollDismissesKeyboard(.interactively)
            case .voice: voiceForm
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
            Button { withAnimation(.snappy) { mode = .debrief } } label: {
                debriefHeroRow
            }
            .buttonStyle(.plain)

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

            Button { withAnimation(.snappy) { mode = .voice } } label: {
                entryRow("Voice note", detail: "talk it out — we type it up", symbol: "waveform")
            }
            .buttonStyle(.plain)

            if isPreparing {
                ProgressView("Preparing…")
                    .font(PaperInk.sans(12))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// The headline route — most captures are a few words or a pasted debrief.
    private var debriefHeroRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 24))
                .foregroundStyle(PaperInk.brandDark)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Debrief").display(19).foregroundStyle(PaperInk.ink)
                Text("a few words or your whole lecture notes")
                    .font(PaperInk.sans(12))
                    .foregroundStyle(PaperInk.stone600)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(PaperInk.brandDark)
        }
        .padding(14)
        .background(PaperInk.tint)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(PaperInk.ink, lineWidth: 2))
        .stickerShadow()
        .tilt(-0.5)
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

    /// The debrief route, which also absorbed the old "just words" form:
    /// a title alone is a plain manual capture, while any notes (pasted or
    /// dictated) make it a debrief the AI mines for takeaways.
    private var debriefForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                FieldLabel(text: "What was it?")
                TextField("Taught the FY2s about sepsis", text: $debriefTitle)
                    .font(PaperInk.sans(14))
                    .boxedField()
            }
            VStack(alignment: .leading, spacing: 4) {
                FieldLabel(text: "When")
                DatePicker("", selection: $debriefDate, displayedComponents: .date)
                    .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .bottom) {
                    FieldLabel(text: "Your notes (optional)")
                    Spacer()
                    Button {
                        toggleDictation(into: $debriefNotes, key: "debrief")
                    } label: {
                        Image(systemName: isDebriefRecording ? "stop.circle.fill" : "mic.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(isDebriefRecording ? .red : PaperInk.stone500)
                    }
                    .disabled(transcribing)
                }
                TextField(
                    "What happened, what you took away, what you'd do differently…",
                    text: $debriefNotes,
                    axis: .vertical
                )
                .lineLimit(6 ... 14)
                .font(PaperInk.sans(14))
                .boxedField()
                if transcribing {
                    Text("Tidying up…")
                        .font(PaperInk.sans(11))
                        .foregroundStyle(PaperInk.stone500)
                } else if isDebriefRecording {
                    Text("Listening — tap to stop.")
                        .font(PaperInk.sans(11))
                        .foregroundStyle(PaperInk.stone500)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                FieldLabel(text: "A link (optional)")
                TextField("https://…", text: $debriefURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(PaperInk.sans(14))
                    .boxedField()
            }
            if let dictationError {
                Text(dictationError)
                    .font(PaperInk.sans(12, weight: .semibold))
                    .foregroundStyle(.red)
            }
            formButtons(
                dumpDisabled: (trimmedDebriefTitle.isEmpty && trimmedDebriefNotes.isEmpty)
                    || isDebriefRecording || transcribing
            ) {
                if trimmedDebriefNotes.isEmpty {
                    // Title alone — the plain manual capture, as "just words" was.
                    UploadQueue.shared.enqueueText(title: trimmedDebriefTitle, details: nil, session: session)
                } else {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd"
                    UploadQueue.shared.enqueueDebrief(
                        title: trimmedDebriefTitle,
                        occurredOn: formatter.string(from: debriefDate),
                        notes: debriefNotes,
                        url: normalised(debriefURL),
                        session: session
                    )
                }
                finish()
            }
        }
    }

    private var trimmedDebriefTitle: String {
        debriefTitle.trimmingCharacters(in: .whitespaces)
    }

    private var trimmedDebriefNotes: String {
        debriefNotes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDebriefRecording: Bool {
        recorder.isRecording && recorder.activeKey == "debrief"
    }

    private var isVoiceRecording: Bool {
        recorder.isRecording && recorder.activeKey == "voice"
    }

    /// The in-sheet, text-first voice route: dictate, read it back as
    /// editable words, then dump the text as debrief notes. (The centre mic
    /// FAB still records raw audio via RecordView — this one shows its
    /// working.)
    private var voiceForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(
                "Hit the mic and ramble — we type it up, the AI files it.",
                text: $voiceText,
                axis: .vertical
            )
            .lineLimit(6 ... 14)
            .font(PaperInk.sans(14))
            .boxedField()

            HStack(spacing: 12) {
                Button {
                    toggleDictation(into: $voiceText, key: "voice")
                } label: {
                    Image(systemName: isVoiceRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(isVoiceRecording ? .red : PaperInk.brand)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(PaperInk.ink, lineWidth: 2))
                        .stickerShadow(offset: 3, opacity: 1)
                }
                .disabled(transcribing)

                if transcribing {
                    Text("Tidying up…")
                        .font(PaperInk.sans(12.5))
                        .foregroundStyle(PaperInk.stone500)
                } else if isVoiceRecording {
                    Text("Listening — tap to stop.")
                        .font(PaperInk.sans(12.5))
                        .foregroundStyle(PaperInk.stone500)
                } else {
                    Text("Tap to talk — typing works too.")
                        .font(PaperInk.sans(12.5))
                        .foregroundStyle(PaperInk.stone500)
                }
            }

            if let dictationError {
                Text(dictationError)
                    .font(PaperInk.sans(12, weight: .semibold))
                    .foregroundStyle(.red)
            }

            formButtons(
                dumpDisabled: voiceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || isVoiceRecording || transcribing
            ) {
                UploadQueue.shared.enqueueDebrief(
                    title: nil,
                    occurredOn: nil,
                    notes: voiceText,
                    url: nil,
                    session: session
                )
                finish()
            }
        }
    }

    /// Same pattern as the reflection step's dictation: record a short AAC
    /// clip, transcribe server-side, append to whatever's typed already.
    private func toggleDictation(into text: Binding<String>, key: String) {
        dictationError = nil
        if recorder.isRecording {
            guard let fileURL = recorder.stop() else { return }
            transcribing = true
            Task {
                defer { transcribing = false }
                do {
                    let transcript = try await session.api.transcribe(audioFile: fileURL)
                    text.wrappedValue = text.wrappedValue.isEmpty
                        ? transcript
                        : text.wrappedValue + " " + transcript
                } catch {
                    dictationError = error.localizedDescription
                }
                try? FileManager.default.removeItem(at: fileURL)
            }
        } else {
            Task {
                if await recorder.start(key: key) == false {
                    dictationError = "Microphone access is needed to dictate — enable it in Settings."
                }
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
            Button("Back") {
                // Don't let an in-flight recording bleed into another form.
                if recorder.isRecording, let fileURL = recorder.stop() {
                    try? FileManager.default.removeItem(at: fileURL)
                }
                withAnimation(.snappy) { mode = .menu }
            }
            .font(PaperInk.sans(13, weight: .semibold))
            .foregroundStyle(PaperInk.stone500)
        }
        .padding(.top, 4)
    }

    private var normalisedURL: String? {
        normalised(linkURL)
    }

    private func normalised(_ raw: String) -> String? {
        var candidate = raw.trimmingCharacters(in: .whitespaces)
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
