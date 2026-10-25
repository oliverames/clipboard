//
//  AppDelegate.swift
//  Clipboard
//
//  Created by Riley Testut on 6/10/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import UIKit
import UserNotifications
import AVFoundation

import ClipboardKit
import Roxas

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
    {
        // Override point for customization after application launch.
        print(RoxasVersionNumber)
        
        Diagnostics.shared.log("App launched; state=\(UIApplication.shared.applicationState.rawValue)")
        
        UserDefaults.shared.registerAppDefaults()
        
        func printError<T>(from result: Result<T, Error>, title: String)
        {
            guard let error = result.error else { return }
            print(title, error)
        }
        
        DatabaseManager.shared.prepare() { printError(from: $0, title: "Database Error:") }
        
        ApplicationMonitor.shared.start()
        
        self.registerForNotifications()
        
        #if DEBUG
        // Stages the capture ledger into the app's Documents directory so the device
        // test script can pull it off the phone with devicectl:
        //   devicectl device process launch --environment CLIPBOARD_EXPORT_LEDGER=1 ...
        if ProcessInfo.processInfo.environment["CLIPBOARD_EXPORT_LEDGER"] == "1",
           let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        {
            let exported = CaptureLedger.shared.exportCopy(to: documents.appendingPathComponent("capture-ledger.jsonl"))
            NSLog("Capture ledger export requested; succeeded=%d", exported)
        }

        // Lets a simulator or device run exercise the private reader without
        // going through a notification or URL prompt:
        //   simctl launch --env CLIPBOARD_DAEMON_SELFTEST=1 ...
        if ProcessInfo.processInfo.environment["CLIPBOARD_DAEMON_SELFTEST"] == "1"
        {
            NSLog("Pasteboard daemon reader available: %d", PasteboardDaemonReader.isAvailable())
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSLog("Running pasteboard daemon self-test.")
                ApplicationMonitor.shared.pasteboardMonitor.savePasteboardUsingDaemonReader()
            }
        }
        #endif
        
        return true
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate
{
    private func registerForNotifications()
    {
        let category = UNNotificationCategory(identifier: UNNotificationCategory.clipboardReaderIdentifier, actions: [], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
        
        UNUserNotificationCenter.current().delegate = self
        
        // Only ask for permission when it hasn't been decided yet. Asking again on every
        // launch puts a system alert on screen, which is distracting for no reason.
        UNUserNotificationCenter.current().getNotificationSettings { (settings) in
            guard settings.authorizationStatus == .notDetermined else { return }
            
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { (success, error) in
            }
        }
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void)
    {
        completionHandler(.alert)
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void)
    {
        guard response.notification.request.content.categoryIdentifier == UNNotificationCategory.clipboardReaderIdentifier else { return }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        
        let location = ApplicationMonitor.shared.locationManager.location
        
        // Delay until next run loop so UIPasteboard no longer returns nil items due to being in background.
        DispatchQueue.main.async {
            DatabaseManager.shared.savePasteboard(location: location) { (result) in
                switch result
                {
                case .success: break
                case .failure(PasteboardError.duplicateItem): break
                    
                case .failure(let error):
                    DispatchQueue.main.async {
                        // Scenes own the windows, so let the active scene present the alert.
                        NotificationCenter.default.post(name: .clipboardSaveFailed, object: nil, userInfo: [NSUnderlyingErrorKey: error])
                    }
                }
                
                print("Save clipboard with result:", result)
                
                completionHandler()
            }
        }
    }
}

extension Notification.Name
{
    static let clipboardSaveFailed = Notification.Name("com.rileytestut.Clip.clipboardSaveFailed")
}
