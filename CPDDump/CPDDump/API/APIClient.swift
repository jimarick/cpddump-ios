import Foundation

/// Errors surfaced to the UI with the server's own message where possible.
struct APIError: LocalizedError {
    var status: Int
    var message: String
    /// Laravel validation errors keyed by field.
    var fieldErrors: [String: [String]] = [:]

    var errorDescription: String? { message }

    var needsTwoFactorCode: Bool {
        status == 422 && fieldErrors.keys.contains("code")
    }
}

extension Error {
    /// SwiftUI cancels `.task` / `.refreshable` work whenever view identity
    /// changes mid-flight; the resulting errors ("cancelled") are noise,
    /// not failures to show the user.
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}

/// Thin async client for the CPD Dump companion API (`/api/v1`).
struct APIClient {
    var baseURL: URL
    var token: String?

    private var apiRoot: URL { baseURL.appending(path: "api/v1") }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder = JSONEncoder()

    // MARK: Auth

    func requestToken(email: String, password: String, code: String?, deviceName: String) async throws -> TokenResponse {
        var body: [String: String] = ["email": email, "password": password, "device_name": deviceName]
        if let code, !code.isEmpty { body["code"] = code }
        return try await send("POST", "auth/token", json: body)
    }

    func revokeToken() async throws {
        try await sendIgnoringBody("DELETE", "auth/token")
    }

    func me() async throws -> UserPayload {
        struct Wrapper: Codable { var user: UserPayload }
        let wrapper: Wrapper = try await send("GET", "user")
        return wrapper.user
    }

    // MARK: Inbox

    func inboxItems() async throws -> [InboxItem] {
        struct Wrapper: Codable { var items: [InboxItem] }
        let wrapper: Wrapper = try await send("GET", "inbox-items")
        return wrapper.items
    }

    func inboxItem(id: Int) async throws -> InboxItem {
        struct Wrapper: Codable { var item: InboxItem }
        let wrapper: Wrapper = try await send("GET", "inbox-items/\(id)")
        return wrapper.item
    }

    func approve(id: Int, payload: ApprovePayload) async throws {
        _ = try await raw("POST", "inbox-items/\(id)/approve", body: try Self.encoder.encode(payload))
    }

    /// Bin an item; optionally leave an ignore rule so items whose title
    /// contains the given text never appear again.
    func dismiss(id: Int, neverAgainTitle: String? = nil) async throws {
        if let value = neverAgainTitle, !value.isEmpty {
            let body = try JSONSerialization.data(withJSONObject: [
                "ignore_rule": ["field": "title", "operator": "contains", "value": value],
            ])
            _ = try await raw("DELETE", "inbox-items/\(id)", body: body)
        } else {
            try await sendIgnoringBody("DELETE", "inbox-items/\(id)")
        }
    }

    func retry(id: Int) async throws {
        try await sendIgnoringBody("POST", "inbox-items/\(id)/retry")
    }

    /// Purge stored files to stubs and scrub identifiers — lifts the PII gate.
    func removePii(id: Int) async throws -> InboxItem {
        struct Wrapper: Codable { var item: InboxItem }
        let wrapper: Wrapper = try await send("POST", "inbox-items/\(id)/remove-pii")
        return wrapper.item
    }

    // MARK: Merging

    func mergeCandidates(periodId: Int? = nil) async throws -> MergeCandidates {
        var query: [URLQueryItem] = []
        if let periodId { query.append(URLQueryItem(name: "period_id", value: String(periodId))) }
        return try await send("GET", "merges/candidates", query: query)
    }

    func mergePreview(seed: MergeSeed) async throws -> MergePreview {
        try await send("POST", "merges/preview", body: try Self.encoder.encode(seed))
    }

    /// The AI-drafted combined entry for the merge sheet — costs tokens, on demand.
    func mergeDraft(seed: MergeSeed) async throws -> MergeDraft {
        struct Wrapper: Codable { var draft: MergeDraft }
        let wrapper: Wrapper = try await send("POST", "merges/draft", body: try Self.encoder.encode(seed))
        return wrapper.draft
    }

    /// Returns the merged activity's id.
    func merge(payload: MergePayload) async throws -> Int {
        struct Wrapper: Codable {
            var activityId: Int
            enum CodingKeys: String, CodingKey { case activityId = "activity_id" }
        }
        let wrapper: Wrapper = try await send("POST", "merges", body: try Self.encoder.encode(payload))
        return wrapper.activityId
    }

    /// Splits a merged entry; returns the released activity ids.
    func unmerge(activityId: Int) async throws -> [Int] {
        struct Wrapper: Codable {
            var activityIds: [Int]
            enum CodingKeys: String, CodingKey { case activityIds = "activity_ids" }
        }
        let wrapper: Wrapper = try await send("POST", "activities/\(activityId)/unmerge")
        return wrapper.activityIds
    }

    // MARK: Timeline

    func activities(page: Int = 1, periodId: Int? = nil) async throws -> ActivitiesPage {
        var query = [URLQueryItem(name: "page", value: String(page))]
        if let periodId { query.append(URLQueryItem(name: "period", value: String(periodId))) }
        return try await send("GET", "activities", query: query)
    }

    func activity(id: Int) async throws -> ActivityDetail {
        struct Wrapper: Codable { var activity: ActivityDetail }
        let wrapper: Wrapper = try await send("GET", "activities/\(id)")
        return wrapper.activity
    }

    func updateActivity(id: Int, payload: UpdateActivityPayload) async throws -> ActivityDetail {
        struct Wrapper: Codable { var activity: ActivityDetail }
        let wrapper: Wrapper = try await send("PUT", "activities/\(id)", body: try Self.encoder.encode(payload))
        return wrapper.activity
    }

    // MARK: Takeaways

    /// Every current-period activity with at least one nugget or action.
    func fetchTakeaways() async throws -> TakeawaysResponse {
        try await send("GET", "takeaways")
    }

    /// Tick/un-tick, reword, or re-kind one nugget/action; returns the
    /// activity's fresh lists.
    func updateTakeaway(activityId: Int, itemId: String, done: Bool? = nil, kind: String? = nil, text: String? = nil) async throws -> TakeawayLists {
        var body: [String: Any] = [:]
        if let done { body["done"] = done }
        if let kind { body["kind"] = kind }
        if let text { body["text"] = text }
        return try await send(
            "PATCH",
            "activities/\(activityId)/takeaways/\(itemId)",
            body: try JSONSerialization.data(withJSONObject: body)
        )
    }

    func deleteTakeaway(activityId: Int, itemId: String) async throws -> TakeawayLists {
        try await send("DELETE", "activities/\(activityId)/takeaways/\(itemId)")
    }

    /// Opt in after the fact: AI-extract (and save) takeaways for an
    /// activity that has none. 422 when it already has some or the AI
    /// failed, 429 on budget — both carry a `message`.
    func generateTakeaways(activityId: Int) async throws -> TakeawayLists {
        try await send("POST", "activities/\(activityId)/takeaways/generate")
    }

    /// Post-approval remedy: purge stored files to stubs and scrub
    /// identifiers from the entry's text — the entry itself is kept.
    func removeActivityPii(id: Int) async throws -> ActivityDetail {
        struct Wrapper: Codable { var activity: ActivityDetail }
        let wrapper: Wrapper = try await send("POST", "activities/\(id)/remove-pii")
        return wrapper.activity
    }

    /// Download an evidence file (streamed with the bearer token) into a
    /// temporary file named for QuickLook to preview.
    func downloadAttachment(id: Int, suggestedName: String?) async throws -> URL {
        let data = try await raw("GET", "attachments/\(id)")
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "attachments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = (suggestedName?.isEmpty == false ? suggestedName! : "attachment-\(id)")
        let url = directory.appending(path: name)
        try data.write(to: url)
        return url
    }

    /// Deletes a kept evidence file. The attachment survives server-side as
    /// an honest "not kept" stub — the written entry is untouched.
    func deleteAttachment(id: Int) async throws {
        try await sendIgnoringBody("DELETE", "attachments/\(id)")
    }

    // MARK: Reference & stats

    func reference() async throws -> Reference {
        try await send("GET", "reference")
    }

    func stats(periodId: Int? = nil) async throws -> StatsResponse {
        var query: [URLQueryItem] = []
        if let periodId { query.append(URLQueryItem(name: "period", value: String(periodId))) }
        return try await send("GET", "stats", query: query)
    }

    // MARK: Push

    func registerPushToken(_ token: String, deviceName: String) async throws {
        _ = try await raw("POST", "push-tokens", json: [
            "token": token,
            "platform": "ios",
            "device_name": deviceName,
        ])
    }

    /// Push preferences; returns the full fresh user payload.
    func updatePreferences(weeklyNudge: Bool? = nil, morningGem: Bool? = nil) async throws -> UserPayload {
        struct Wrapper: Codable { var user: UserPayload }
        var body: [String: Any] = [:]
        if let weeklyNudge { body["push_weekly_nudge_enabled"] = weeklyNudge }
        if let morningGem { body["push_morning_gem_enabled"] = morningGem }
        let wrapper: Wrapper = try await send("PATCH", "user/preferences", body: try JSONSerialization.data(withJSONObject: body))
        return wrapper.user
    }

    // MARK: AI assist

    func textAssist(field: String, text: String?, context: String?) async throws -> String {
        struct Wrapper: Codable { var text: String }
        var body: [String: String] = ["field": field]
        if let text, !text.isEmpty { body["text"] = text }
        if let context, !context.isEmpty { body["context"] = context }
        let wrapper: Wrapper = try await send("POST", "ai/text-assist", json: body)
        return wrapper.text
    }

    /// The review wizard's single AI pass: the user's notes plus the facts
    /// in; details, reflections, takeaways and silent categorisation out.
    func composeReview(
        notes: String,
        title: String? = nil,
        activityTypeSlug: String? = nil,
        startsOn: String? = nil,
        organisation: String? = nil,
        cpdPoints: Double? = nil
    ) async throws -> ComposedReview {
        var body: [String: Any] = ["notes": notes]
        if let title, !title.isEmpty { body["title"] = title }
        if let activityTypeSlug, !activityTypeSlug.isEmpty { body["activity_type_slug"] = activityTypeSlug }
        if let startsOn { body["starts_on"] = startsOn }
        if let organisation, !organisation.isEmpty { body["organisation"] = organisation }
        if let cpdPoints { body["cpd_points"] = cpdPoints }
        return try await send("POST", "ai/compose-review", body: try JSONSerialization.data(withJSONObject: body))
    }

    /// The talk-first capture: one ramble in, an answer per reflection
    /// prompt out — nil for prompts the ramble doesn't support.
    func reflectionDraft(text: String, context: String?) async throws -> [String: String?] {
        struct Wrapper: Codable { var reflection: [String: String?] }
        var body: [String: String] = ["text": text]
        if let context, !context.isEmpty { body["context"] = context }
        let wrapper: Wrapper = try await send("POST", "ai/reflection-draft", json: body)
        return wrapper.reflection
    }

    func transcribe(audioFile: URL) async throws -> String {
        struct Wrapper: Codable { var text: String }
        let audio = try Data(contentsOf: audioFile)
        let multipart = MultipartBody()
        multipart.addFile(name: "audio", filename: audioFile.lastPathComponent, mimeType: "audio/mp4", data: audio)
        let wrapper: Wrapper = try await send("POST", "ai/transcribe", body: multipart.encoded(), contentType: multipart.contentType)
        return wrapper.text
    }

    // MARK: Core request machinery

    private func send<Response: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        json: [String: String]? = nil,
        body: Data? = nil,
        contentType: String = "application/json"
    ) async throws -> Response {
        let data = try await raw(method, path, query: query, json: json, body: body, contentType: contentType)
        return try Self.decoder.decode(Response.self, from: data)
    }

    private func sendIgnoringBody(_ method: String, _ path: String) async throws {
        _ = try await raw(method, path)
    }

    private func raw(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        json: [String: String]? = nil,
        body: Data? = nil,
        contentType: String = "application/json"
    ) async throws -> Data {
        var url = apiRoot.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200 ..< 300).contains(status) else {
            throw Self.error(from: data, status: status)
        }
        return data
    }

    private static func error(from data: Data, status: Int) -> APIError {
        struct LaravelError: Codable {
            var message: String?
            var errors: [String: [String]]?
        }
        if let parsed = try? JSONDecoder().decode(LaravelError.self, from: data) {
            return APIError(
                status: status,
                message: parsed.message ?? "Something went wrong (\(status)).",
                fieldErrors: parsed.errors ?? [:]
            )
        }
        if status == 401 { return APIError(status: status, message: "Signed out — please sign in again.") }
        return APIError(status: status, message: "Something went wrong (\(status)).")
    }
}

/// Builds multipart/form-data bodies (files + fields).
final class MultipartBody {
    private let boundary = "cpddump-\(UUID().uuidString)"
    private var data = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    func addField(name: String, value: String) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    func addFile(name: String, filename: String, mimeType: String, data fileData: Data) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        data.append(fileData)
        data.append(Data("\r\n".utf8))
    }

    func encoded() -> Data {
        data + Data("--\(boundary)--\r\n".utf8)
    }
}
