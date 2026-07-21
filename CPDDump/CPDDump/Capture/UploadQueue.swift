import Foundation
import Observation

/// Captures survive app suspension: multipart bodies live in the App Group
/// container and are handed to a background URLSession; manifests persist
/// across launches so failed uploads can be retried. The share extension
/// enqueues into the same container with its own background session — iOS
/// relaunches the app when those finish, and we adopt the results here.
@Observable
final class UploadQueue: NSObject {
    static let shared = UploadQueue()

    typealias Pending = SharedStorage.QueuedUpload

    /// App-queued uploads (retryable) followed by extension-queued ones.
    private(set) var items: [Pending] = []
    private var extItems: [Pending] = []

    /// Called after a capture reaches the server — the inbox refreshes itself.
    var onUploaded: (() -> Void)?

    /// Stored by the app delegate when iOS relaunches us for background events.
    var backgroundCompletionHandler: (() -> Void)?

    private var urlSession: URLSession!
    private var extensionSession: URLSession?

    private var directory: URL { SharedStorage.uploadsDirectory }

    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: SharedStorage.appSessionId)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        // Anything still in the app manifest at launch either failed or never
        // finished — mark it retryable, then un-mark whatever is still running.
        items = SharedStorage.readManifest(SharedStorage.appManifest).map { entry in
            var entry = entry
            entry.failed = true
            return entry
        }
        reconcileWithRunningTasks()
        syncExtensionQueue()
    }

    // MARK: Enqueue

    func enqueueAudio(fileURL: URL, session: Session) {
        let multipart = MultipartBody()
        if let data = try? Data(contentsOf: fileURL) {
            multipart.addFile(name: "audio", filename: "voice-note.m4a", mimeType: "audio/mp4", data: data)
        }
        try? FileManager.default.removeItem(at: fileURL)
        enqueue(multipart, label: "Voice note", symbol: "mic.fill", session: session)
    }

    func enqueueFiles(_ files: [(data: Data, filename: String, mimeType: String)], session: Session) {
        let multipart = MultipartBody()
        var labelName = files.first?.filename ?? "Upload"
        for file in files.prefix(5) {
            let converted = ImageTranscoder.normalise(data: file.data, filename: file.filename, mimeType: file.mimeType)
            multipart.addFile(name: "files[]", filename: converted.filename, mimeType: converted.mimeType, data: converted.data)
            if file.filename == labelName { labelName = converted.filename }
        }
        let label = files.count == 1 ? labelName : "\(files.count) files"
        enqueue(multipart, label: label, symbol: "photo", session: session)
    }

    func enqueueLink(_ url: String, note: String?, session: Session) {
        let multipart = MultipartBody()
        multipart.addField(name: "url", value: url)
        if let note, !note.isEmpty { multipart.addField(name: "details", value: note) }
        enqueue(multipart, label: url, symbol: "link", session: session)
    }

    func enqueueText(title: String, details: String?, session: Session) {
        let multipart = MultipartBody()
        multipart.addField(name: "title", value: title)
        if let details, !details.isEmpty { multipart.addField(name: "details", value: details) }
        enqueue(multipart, label: title, symbol: "square.and.pencil", session: session)
    }

    /// Debrief notes: pasted/dictated text, optionally with the day it
    /// happened — the server files it as source "debrief" and mines the
    /// takeaways.
    func enqueueDebrief(title: String?, occurredOn: String?, notes: String, url: String?, session: Session) {
        let multipart = MultipartBody()
        if let title, !title.isEmpty { multipart.addField(name: "title", value: title) }
        if let occurredOn, !occurredOn.isEmpty { multipart.addField(name: "occurred_on", value: occurredOn) }
        multipart.addField(name: "notes", value: notes)
        if let url, !url.isEmpty { multipart.addField(name: "url", value: url) }
        let label = title?.isEmpty == false ? title! : "Debrief notes"
        enqueue(multipart, label: label, symbol: "list.bullet.clipboard", session: session)
    }

    private func enqueue(_ multipart: MultipartBody, label: String, symbol: String, session: Session) {
        let id = UUID()
        let bodyFile = directory.appending(path: "\(id.uuidString).body")
        do {
            try multipart.encoded().write(to: bodyFile)
        } catch {
            return
        }

        let pending = Pending(
            id: id,
            label: label,
            sourceSymbol: symbol,
            bodyFile: bodyFile.lastPathComponent,
            contentType: multipart.contentType,
            createdAt: .now
        )
        items.append(pending)
        saveManifest()
        startTask(for: pending, token: session.token)
    }

    func retry(_ item: Pending, session: Session) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].failed = false
        startTask(for: items[index], token: session.token)
    }

    func discard(_ item: Pending) {
        try? FileManager.default.removeItem(at: directory.appending(path: item.bodyFile))
        items.removeAll { $0.id == item.id }
        saveManifest()
    }

    /// Pull-to-refresh means "mirror the server": clear every failed local
    /// note (and its stored body) so the tray shows only live uploads and
    /// real server items.
    func clearFailed() {
        for item in items where item.failed {
            try? FileManager.default.removeItem(at: directory.appending(path: item.bodyFile))
        }
        items.removeAll(where: \.failed)
        saveManifest()
    }

    private func startTask(for pending: Pending, token: String?) {
        let request = SharedStorage.captureRequest(contentType: pending.contentType, token: token)
        let task = urlSession.uploadTask(with: request, fromFile: directory.appending(path: pending.bodyFile))
        task.taskDescription = pending.id.uuidString
        task.resume()
    }

    /// If iOS kept tasks alive across a relaunch, don't double-mark them failed.
    private func reconcileWithRunningTasks() {
        urlSession.getAllTasks { tasks in
            let runningIds = Set(tasks.compactMap(\.taskDescription))
            Task { @MainActor in
                for index in self.items.indices where runningIds.contains(self.items[index].id.uuidString) {
                    self.items[index].failed = false
                }
            }
        }
    }

    private func saveManifest() {
        SharedStorage.writeManifest(items, to: SharedStorage.appManifest)
    }

    // MARK: Extension uploads

    /// Adopt uploads the share extension queued: attach to its background
    /// session (draining any finished events), and adopt whatever's left.
    /// Called at launch, on foreground, and when iOS relaunches us for the
    /// extension's session events.
    func syncExtensionQueue() {
        extItems = SharedStorage.readManifest(SharedStorage.extensionManifest)
        guard !extItems.isEmpty || extensionSession != nil else { return }

        ensureExtensionSession().getAllTasks { tasks in
            let runningIds = Set(tasks.compactMap(\.taskDescription))
            Task { @MainActor in
                // Adopt entries the extension already marked failed, plus
                // true corpses: no live task and old enough that a pending
                // completion event can't still be on its way.
                var remaining = SharedStorage.readManifest(SharedStorage.extensionManifest)
                let orphans = remaining.filter { entry in
                    entry.failed || (
                        !runningIds.contains(entry.id.uuidString)
                            && entry.createdAt < Date.now.addingTimeInterval(-300)
                    )
                }
                guard !orphans.isEmpty else {
                    self.extItems = remaining
                    return
                }
                remaining.removeAll { entry in orphans.contains { $0.id == entry.id } }
                SharedStorage.writeManifest(remaining, to: SharedStorage.extensionManifest)
                self.extItems = remaining
                for var orphan in orphans {
                    orphan.failed = true
                    self.items.append(orphan)
                }
                self.saveManifest()
            }
        }
    }

    @discardableResult
    private func ensureExtensionSession() -> URLSession {
        if let extensionSession { return extensionSession }
        let config = URLSessionConfiguration.background(withIdentifier: SharedStorage.extensionSessionId)
        config.sharedContainerIdentifier = SharedStorage.appGroup
        config.sessionSendsLaunchEvents = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        extensionSession = session
        return session
    }

    func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
        if identifier == SharedStorage.extensionSessionId {
            syncExtensionQueue()
        }
    }

    /// Everything the tray should show, newest first within each group.
    var visibleItems: [Pending] { extItems + items }

    private func finish(taskId: String, success: Bool, status: Int) {
        if let index = items.firstIndex(where: { $0.id.uuidString == taskId }) {
            if success {
                try? FileManager.default.removeItem(at: directory.appending(path: items[index].bodyFile))
                items.remove(at: index)
                saveManifest()
                onUploaded?()
            } else {
                items[index].failed = true
                items[index].failureStatus = status
                saveManifest()
                NotificationManager.shared.notifyUploadFailed(items[index])
            }
            return
        }

        // Extension-queued upload finishing in our process.
        var entries = SharedStorage.readManifest(SharedStorage.extensionManifest)
        guard let index = entries.firstIndex(where: { $0.id.uuidString == taskId }) else { return }
        let entry = entries.remove(at: index)
        SharedStorage.writeManifest(entries, to: SharedStorage.extensionManifest)
        extItems = entries
        if success {
            try? FileManager.default.removeItem(at: directory.appending(path: entry.bodyFile))
            onUploaded?()
        } else {
            var failed = entry
            failed.failed = true
            failed.failureStatus = status
            items.append(failed)
            saveManifest()
            NotificationManager.shared.notifyUploadFailed(failed)
        }
    }
}

extension UploadQueue: URLSessionTaskDelegate, URLSessionDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskId = task.taskDescription ?? ""
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let success = error == nil && (200 ..< 300).contains(status)
        Task { @MainActor in
            UploadQueue.shared.finish(taskId: taskId, success: success, status: status)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            UploadQueue.shared.backgroundCompletionHandler?()
            UploadQueue.shared.backgroundCompletionHandler = nil
        }
    }
}
