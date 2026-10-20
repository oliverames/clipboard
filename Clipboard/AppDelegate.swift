//
//  AppDelegate.swift
//  Clipboard
//
//  Created by Riley Testut on 6/10/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import UIKit
import UserNotifications

import ClipboardKit
import Roxas

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
    {
        // Override point for customization after application launch.
        print(RoxasVersionNumber)
        
        UserDefaults.shared.registerAppDefaults()
        
        func printError<T>(from result: Result<T, Error>, title: String)
        {
            guard let error = result.error else { return }
            print(title, error)
        }
        
        DatabaseManager.shared.prepare() { printError(from: $0, title: "Database Error:") }
        
        ApplicationMonitor.shared.start()
        
        self.registerForNotifications()
        
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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { (success, error) in
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
