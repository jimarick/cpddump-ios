import Foundation
import Observation
import UIKit

/// App-wide auth + reference state. Token lives in the Keychain, server URL
/// in UserDefaults (editable on the sign-in screen for dev builds).
@Observable
final class Session {
    private(set) var token: String?
    private(set) var user: UserPayload?
    private(set) var reference: Reference?

    var serverURLString: String {
        didSet { SharedStorage.serverURLString = serverURLString }
    }

    var isSignedIn: Bool { token != nil }

    init() {
        // Migrate the server URL into group defaults so the share extension
        // sees the same server.
        if let legacy = UserDefaults.standard.string(forKey: "serverURL"),
           SharedStorage.defaults.string(forKey: "serverURL") == nil {
            SharedStorage.serverURLString = legacy
        }
        serverURLString = SharedStorage.serverURLString

        token = Keychain.read(account: "token")
        if let token {
            // Re-save so tokens stored before Keychain Sharing existed move
            // into the shared access group the extension can read.
            Keychain.save(token, account: "token")
        }
        if let data = UserDefaults.standard.data(forKey: "user") {
            user = try? JSONDecoder().decode(UserPayload.self, from: data)
        }
    }

    var api: APIClient {
        APIClient(baseURL: URL(string: serverURLString) ?? URL(string: "https://cpd-dump.test")!, token: token)
    }

    func signIn(email: String, password: String, code: String?) async throws {
        let response = try await api.requestToken(
            email: email,
            password: password,
            code: code,
            deviceName: UIDevice.current.name
        )
        token = response.token
        user = response.user
        Keychain.save(response.token, account: "token")
        if let data = try? JSONEncoder().encode(response.user) {
            UserDefaults.standard.set(data, forKey: "user")
        }
        // Sign-out deletes push tokens server-side — put ours back.
        NotificationManager.shared.registerIfAuthorized()
    }

    func signOut() async {
        try? await api.revokeToken()
        token = nil
        user = nil
        reference = nil
        Keychain.delete(account: "token")
        UserDefaults.standard.removeObject(forKey: "user")
    }

    /// Called when any request comes back 401 — the token was revoked server-side.
    func handleUnauthorised() {
        token = nil
        Keychain.delete(account: "token")
    }

    /// Settings like attachment retention can change on the web — refresh
    /// the cached identity once per launch.
    func refreshUser() async {
        guard isSignedIn, let fresh = try? await api.me() else { return }
        user = fresh
        if let data = try? JSONEncoder().encode(fresh) {
            UserDefaults.standard.set(data, forKey: "user")
        }
    }

    /// Reference data is stable; fetch once per launch and cache in memory.
    @discardableResult
    func loadReference() async -> Reference? {
        if let reference { return reference }
        reference = try? await api.reference()
        return reference
    }
}
