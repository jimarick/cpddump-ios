import Foundation

/// Everything the app and the share extension share: the App Group container
/// (upload bodies + manifests), group UserDefaults (server URL), and the
/// background-session naming that lets extension uploads finish in the app.
enum SharedStorage {
    static let appGroup = "group.com.cpddump.CPDDump"

    /// Background URLSession identifiers. The extension uses its own — when
    /// its uploads finish, iOS launches the app with this identifier.
    static let appSessionId = "com.cpddump.CPDDump.uploads"
    static let extensionSessionId = "com.cpddump.CPDDump.uploads.ext"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    static var container: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var uploadsDirectory: URL {
        let directory = container.appending(path: "uploads")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var appManifest: URL { uploadsDirectory.appending(path: "manifest.json") }
    static var extensionManifest: URL { uploadsDirectory.appending(path: "manifest-ext.json") }

    /// Release builds always talk to production; debug builds default to the
    /// local Herd server but can be pointed anywhere via Server settings.
    static let defaultServer = "https://cpddump.com"

    static var serverURLString: String {
        get {
            #if DEBUG
            defaults.string(forKey: "serverURL") ?? "https://cpd-dump.test"
            #else
            defaultServer
            #endif
        }
        set { defaults.set(newValue, forKey: "serverURL") }
    }

    static var serverURL: URL {
        URL(string: serverURLString) ?? URL(string: defaultServer)!
    }

    /// An entry in either manifest.
    struct QueuedUpload: Identifiable, Codable {
        var id: UUID
        var label: String
        var sourceSymbol: String
        var bodyFile: String
        var contentType: String
        var createdAt: Date
        var failed = false
        /// HTTP status of the last failed attempt (0 = network error).
        var failureStatus: Int?

        var failureText: String {
            switch failureStatus {
            case .none: "Upload failed"
            case 0: "No connection"
            case 401: "Signed out"
            case 413: "Too large for server"
            case 422: "Server rejected it"
            case 429: "Daily limit reached"
            case .some(let code): "Failed (\(code))"
            }
        }
    }

    static func readManifest(_ url: URL) -> [QueuedUpload] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([QueuedUpload].self, from: data)) ?? []
    }

    static func writeManifest(_ entries: [QueuedUpload], to url: URL) {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url)
        }
    }

    /// The capture request both processes upload to.
    static func captureRequest(contentType: String, token: String?) -> URLRequest {
        var request = URLRequest(url: serverURL.appending(path: "api/v1/inbox-items"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
