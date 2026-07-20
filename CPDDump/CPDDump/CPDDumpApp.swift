//
//  CPDDumpApp.swift
//  CPDDump
//
//  Created by Dev on 18/07/2026.
//

import SwiftUI

/// Background-upload relaunch handling + push-notification registration.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NotificationManager.shared.bootstrap()
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        UploadQueue.shared.handleBackgroundEvents(identifier: identifier, completionHandler: completionHandler)
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NotificationManager.shared.uploadDeviceToken(deviceToken)
    }
}

@main
struct CPDDumpApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = Session()

    init() {
        PaperInk.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if session.isSignedIn {
                    MainTabView()
                } else {
                    SignInView()
                }
            }
            .environment(session)
            .tint(PaperInk.brand)
        }
    }
}
