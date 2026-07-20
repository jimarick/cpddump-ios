//
//  ShareViewController.swift
//  CPDDumpShare
//

import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// Principal class of the share extension: hosts the SwiftUI card over a
/// dimmed backdrop, loads whatever was shared, and hands the payload to a
/// background upload the main app adopts.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        PaperInk.registerFonts()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.3)

        let host = UIHostingController(
            rootView: ShareCardView(
                context: extensionContext,
                onDone: { [weak self] in
                    self?.extensionContext?.completeRequest(returningItems: nil)
                },
                onCancel: { [weak self] in
                    self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
                }
            )
        )
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }
}

/// What arrived through the share sheet.
enum SharedPayload {
    case link(URL)
    case files([(data: Data, filename: String, mimeType: String)])
    case text(String)
}

struct ShareCardView: View {
    let context: NSExtensionContext?
    var onDone: () -> Void
    var onCancel: () -> Void

    @State private var payload: SharedPayload?
    @State private var loadFailed = false
    @State private var note = ""
    @State private var isDumping = false

    private var signedIn: Bool { Keychain.read(account: "token") != nil }

    var body: some View {
        VStack {
            Spacer()
            card
                .padding(.horizontal, 14)
                .padding(.bottom, 24)
        }
        .task { await loadPayload() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drop it on the pile")
                .font(PaperInk.display(22))
                .kerning(22 * -0.03)

            if !signedIn {
                Text("Sign in to CPD Dump first, then share again.")
                    .font(PaperInk.sans(13, weight: .semibold))
                    .foregroundStyle(PaperInk.stone600)
            } else if loadFailed {
                Text("Couldn't read what was shared — try again.")
                    .font(PaperInk.sans(13, weight: .semibold))
                    .foregroundStyle(.red)
            } else if let payload {
                summary(payload)

                VStack(alignment: .leading, spacing: 4) {
                    Text(noteLabel(payload))
                        .font(PaperInk.sans(10, weight: .heavy))
                        .textCase(.uppercase)
                        .kerning(0.8)
                        .foregroundStyle(PaperInk.stone500)
                    TextField("Why does it matter to you?", text: $note, axis: .vertical)
                        .font(PaperInk.sans(14))
                        .lineLimit(2 ... 4)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PaperInk.ink.opacity(0.35), lineWidth: 1.5))
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Reading what you shared…")
                        .font(PaperInk.sans(13))
                        .foregroundStyle(PaperInk.stone500)
                }
                .padding(.vertical, 8)
            }

            HStack(spacing: 14) {
                if signedIn && payload != nil {
                    Button {
                        dump()
                    } label: {
                        HStack(spacing: 7) {
                            Sparkle(size: 14, color: .white)
                            Text(isDumping ? "Dumping…" : "Dump it")
                        }
                    }
                    .buttonStyle(InkButtonStyle(prominent: true))
                    .disabled(isDumping)
                }

                Button("Cancel") { onCancel() }
                    .font(PaperInk.sans(14, weight: .semibold))
                    .foregroundStyle(PaperInk.stone500)
            }
            .padding(.top, 2)

            Text("Uploads in the background — the AI does the filing.")
                .font(PaperInk.sans(11))
                .foregroundStyle(PaperInk.stone500)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PaperInk.paper)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(PaperInk.ink, lineWidth: 2.5))
        .stickerShadow(offset: 4, opacity: 1)
        .tilt(-0.5)
    }

    private func summary(_ payload: SharedPayload) -> some View {
        Group {
            switch payload {
            case .link(let url):
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 13))
                        .foregroundStyle(PaperInk.brandDark)
                    Text(url.absoluteString)
                        .font(PaperInk.sans(12, weight: .semibold))
                        .lineLimit(2)
                }
            case .files(let files):
                HStack(spacing: 8) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13))
                        .foregroundStyle(PaperInk.brandDark)
                    Text(files.count == 1 ? files[0].filename : "\(files.count) files")
                        .font(PaperInk.sans(12, weight: .semibold))
                        .lineLimit(1)
                }
            case .text(let text):
                Text(text)
                    .font(PaperInk.sans(12))
                    .foregroundStyle(PaperInk.stone600)
                    .lineLimit(3)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(PaperInk.stone400, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        )
    }

    private func noteLabel(_ payload: SharedPayload) -> String {
        if case .link = payload { return "Anything the page doesn't say? (optional)" }
        return "Anything to add? (optional)"
    }

    // MARK: Loading

    private func loadPayload() async {
        let providers = (context?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []

        // A web URL wins; otherwise gather files; otherwise plain text.
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            && !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = try? await provider.loadURL() {
                payload = .link(url)
                return
            }
        }

        var files: [(data: Data, filename: String, mimeType: String)] = []
        for provider in providers.prefix(5) {
            if let file = try? await provider.loadFile() {
                files.append(file)
            }
        }
        if !files.isEmpty {
            payload = .files(files)
            return
        }

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await provider.loadText(), !text.isEmpty {
                payload = .text(text)
                return
            }
        }

        loadFailed = true
    }

    // MARK: Upload

    private func dump() {
        guard let payload else { return }
        isDumping = true

        let multipart = MultipartBody()
        let label: String
        let symbol: String
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)

        switch payload {
        case .link(let url):
            multipart.addField(name: "url", value: url.absoluteString)
            if !trimmedNote.isEmpty { multipart.addField(name: "details", value: trimmedNote) }
            label = url.absoluteString
            symbol = "link"
        case .files(let files):
            for file in files.prefix(5) {
                let converted = ImageTranscoder.normalise(data: file.data, filename: file.filename, mimeType: file.mimeType)
                multipart.addFile(name: "files[]", filename: converted.filename, mimeType: converted.mimeType, data: converted.data)
            }
            if !trimmedNote.isEmpty { multipart.addField(name: "details", value: trimmedNote) }
            label = files.count == 1 ? files[0].filename : "\(files.count) files"
            symbol = "photo"
        case .text(let text):
            multipart.addField(name: "title", value: String(text.prefix(255)))
            let details = trimmedNote.isEmpty ? text : text + "\n\n" + trimmedNote
            multipart.addField(name: "details", value: details)
            label = String(text.prefix(60))
            symbol = "square.and.pencil"
        }

        let id = UUID()
        let bodyFile = SharedStorage.uploadsDirectory.appending(path: "\(id.uuidString).body")
        do {
            try multipart.encoded().write(to: bodyFile)
        } catch {
            isDumping = false
            loadFailed = true
            return
        }

        var entries = SharedStorage.readManifest(SharedStorage.extensionManifest)
        entries.append(SharedStorage.QueuedUpload(
            id: id,
            label: label,
            sourceSymbol: symbol,
            bodyFile: bodyFile.lastPathComponent,
            contentType: multipart.contentType,
            createdAt: .now
        ))
        SharedStorage.writeManifest(entries, to: SharedStorage.extensionManifest)

        let config = URLSessionConfiguration.background(withIdentifier: SharedStorage.extensionSessionId)
        config.sharedContainerIdentifier = SharedStorage.appGroup
        config.sessionSendsLaunchEvents = true
        let session = URLSession(configuration: config, delegate: ExtensionUploadCleaner.shared, delegateQueue: .main)

        let request = SharedStorage.captureRequest(
            contentType: multipart.contentType,
            token: Keychain.read(account: "token")
        )
        let task = session.uploadTask(with: request, fromFile: bodyFile)
        task.taskDescription = id.uuidString

        // Fast uploads finish while this process is still alive — hold the
        // sheet briefly so the cleaner can settle the manifest entry itself,
        // then hand anything slower to the system + main app.
        var dismissed = false
        let dismiss = {
            guard !dismissed else { return }
            dismissed = true
            onDone()
        }
        ExtensionUploadCleaner.shared.onSettled = { settledId in
            if settledId == id.uuidString { dismiss() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { dismiss() }

        task.resume()
    }
}

/// Settles the extension's own manifest entries when uploads finish before
/// the extension process dies; slower uploads are settled by the main app.
final class ExtensionUploadCleaner: NSObject, URLSessionTaskDelegate {
    static let shared = ExtensionUploadCleaner()

    var onSettled: ((String) -> Void)?

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskId = task.taskDescription ?? ""
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let success = error == nil && (200 ..< 300).contains(status)

        var entries = SharedStorage.readManifest(SharedStorage.extensionManifest)
        if let index = entries.firstIndex(where: { $0.id.uuidString == taskId }) {
            if success {
                let entry = entries.remove(at: index)
                try? FileManager.default.removeItem(
                    at: SharedStorage.uploadsDirectory.appending(path: entry.bodyFile)
                )
            } else {
                entries[index].failed = true
                entries[index].failureStatus = status
            }
            SharedStorage.writeManifest(entries, to: SharedStorage.extensionManifest)
        }
        onSettled?(taskId)
    }
}

// MARK: - NSItemProvider async helpers

private extension NSItemProvider {
    func loadURL() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.url.identifier) { item, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: item as? URL)
            }
        }
    }

    func loadText() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: item as? String ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) })
            }
        }
    }

    /// Loads any file-ish attachment (image, PDF, document) as data + metadata.
    func loadFile() async throws -> (data: Data, filename: String, mimeType: String)? {
        let type = registeredTypeIdentifiers
            .compactMap { UTType($0) }
            .first { $0.conforms(to: .image) || $0.conforms(to: .pdf) || $0.conforms(to: .content) }
        guard let type else { return nil }

        return try await withCheckedThrowingContinuation { continuation in
            loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                if let error { continuation.resume(throwing: error); return }
                guard let url, let data = try? Data(contentsOf: url) else {
                    continuation.resume(returning: nil)
                    return
                }
                let mime = type.preferredMIMEType ?? "application/octet-stream"
                continuation.resume(returning: (data, url.lastPathComponent, mime))
            }
        }
    }
}
