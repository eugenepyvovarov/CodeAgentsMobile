//
//  AppDelegate.swift
//  CodeAgentsMobile
//
//  Purpose: Firebase + APNs bootstrap for push notifications.
//

import UIKit
import UserNotifications
import FirebaseCore
import FirebaseMessaging

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if FirebaseApp.app() == nil {
            if let options = FirebaseOptions.defaultOptions() {
                FirebaseApp.configure(options: options)
            } else {
                NSLog("Firebase not configured: missing GoogleService-Info.plist")
            }
        }

        UNUserNotificationCenter.current().delegate = PushNotificationsManager.shared
        Messaging.messaging().delegate = PushNotificationsManager.shared

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
        Messaging.messaging().apnsToken = deviceToken
        #if DEBUG
        NSLog("APNs device token received (\(deviceToken.count) bytes)")
        #endif
        Task {
            await PushNotificationsManager.shared.refreshSubscriptions()
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("APNs registration failed: \(error.localizedDescription)")
    }
}
