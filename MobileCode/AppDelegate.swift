//
//  AppDelegate.swift
//  CodeAgentsMobile
//
//  Purpose: Firebase + APNs bootstrap for push notifications.
//

import UIKit
import UserNotifications
import FirebaseCore
import FirebaseCrashlytics
import FirebaseMessaging

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let firebaseConfigured = FirebaseBootstrap.configureIfNeeded()

        UNUserNotificationCenter.current().delegate = PushNotificationsManager.shared
        if firebaseConfigured {
            Messaging.messaging().delegate = PushNotificationsManager.shared
        }

        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                application.registerForRemoteNotifications()
            case .notDetermined, .denied:
                break
            @unknown default:
                break
            }
        }

        if let remote = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            PushNotificationsManager.shared.handleLaunchOrTap(userInfo: remote)
        }

        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard FirebaseBootstrap.configureIfNeeded() else { return }
        Messaging.messaging().apnsToken = deviceToken
        #if DEBUG
        NSLog("APNs device token received (\(deviceToken.count) bytes)")
        #endif
        // Force a fresh FCM token once APNs is known. Tokens fetched before APNs
        // is set can be UNREGISTERED at send time even though registration "succeeds".
        Task {
            await PushNotificationsManager.shared.refreshFCMTokenAfterAPNs()
            await PushNotificationsManager.shared.refreshSubscriptions()
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("APNs registration failed: \(error.localizedDescription)")
        SSHLogger.log("APNs registration failed: \(error.localizedDescription)", level: .warning)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            let handled = await PushNotificationsManager.shared.handleRemoteNotification(userInfo: userInfo)
            completionHandler(handled ? .newData : .noData)
        }
    }
}

enum FirebaseBootstrap {
    @discardableResult
    static func configureIfNeeded() -> Bool {
        if FirebaseApp.app() != nil {
            configureCrashReporting()
            return true
        }

        guard let options = FirebaseOptions.defaultOptions() else {
            NSLog("Firebase not configured: missing GoogleService-Info.plist")
            return false
        }

        FirebaseApp.configure(options: options)
        configureCrashReporting()
        return true
    }

    private static func configureCrashReporting() {
        #if DEBUG
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(false)
        #else
        // Release/TestFlight reports contain Firebase's standard pseudonymous crash diagnostics only.
        // Do not add user IDs, custom logs, prompts, paths, URLs, or credentials.
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
        #endif
    }
}
