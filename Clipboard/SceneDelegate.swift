//
//  SceneDelegate.swift
//  Clipboard
//
//  Created by Riley Testut on 10/30/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import UIKit
import UserNotifications
import ClipboardKit

import Roxas

class SceneDelegate: UIResponder, UIWindowSceneDelegate
{
    var window: UIWindow?
    
    private var saveFailureObserver: NSObjectProtocol?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions)
    {
        // Use this method to optionally configure and attach the UIWindow `window` to the provided UIWindowScene `scene`.
        // If using a storyboard, the `window` property will automatically be initialized and attached to the scene.
        // This delegate does not imply the connecting scene or session are new (see `application:configurationForConnectingSceneSession` instead).
        guard let windowScene = (scene as? UIWindowScene) else { return }
        
        self.saveFailureObserver = NotificationCenter.default.addObserver(forName: .clipboardSaveFailed, object: nil, queue: .main) { [weak self, weak windowScene] (notification) in
            guard let self, let windowScene, windowScene.activationState == .foregroundActive else { return }
            guard let error = notification.userInfo?[NSUnderlyingErrorKey] as? Error else { return }
            
            let alertController = UIAlertController(title: NSLocalizedString("Failed to Save Clipboard", comment: ""), message: error.localizedDescription, preferredStyle: .alert)
            alertController.addAction(.ok)
            self.window?.rootViewController?.present(alertController, animated: true, completion: nil)
        }
        
        if let context = connectionOptions.urlContexts.first
        {
            self.open(context)
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene)
    {
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
        
        Diagnostics.shared.log("Scene will enter foreground")
        
        guard DatabaseManager.shared.isStarted else { return }
        
        DatabaseManager.shared.refresh()
        
        guard !UIPasteboard.general.hasImages else {
            // Our duplicate detection does not work for images,
            // so don't automatically save images upon returning to foreground.
            return
        }
        
        let location = ApplicationMonitor.shared.locationManager.location
        DatabaseManager.shared.savePasteboard(location: location) { (result) in
            do
            {
                try result.get()
                print("Saved clipboard upon returning to foreground!")
            }
            catch PasteboardError.noItem, PasteboardError.duplicateItem
            {
                // Ignore
            }
            catch
            {
                print("Failed to save clipboard upon returning to app.")
            }
        }
    }
    
    func sceneDidEnterBackground(_ scene: UIScene)
    {
        // Called as the scene transitions from the foreground to the background.
        // Use this method to save data, release shared resources, and store enough scene-specific state information
        // to restore the scene back to its current state.
        
        Diagnostics.shared.log("Scene did enter background")
        
        #if targetEnvironment(simulator)
        // Audio extension hack to access pasteboard doesn't work in simulator, so for testing just start background task.
        RSTBeginBackgroundTask("com.rileytestut.Clip.simulatorBackgroundTask")
        #endif
        
        DatabaseManager.shared.purge()
    }
    
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>)
    {
        guard let context = URLContexts.first else { return }
        self.open(context)
    }
}

private extension SceneDelegate
{
    func open(_ context: UIOpenURLContext)
    {
        guard context.url.scheme?.lowercased() == "clipboard" else { return }
        
        switch context.url.host?.lowercased()
        {
        case "daemon-reader":
            let components = URLComponents(url: context.url, resolvingAgainstBaseURL: false)
            let value = components?.queryItems?.first(where: { $0.name == "enabled" })?.value?.lowercased()
            
            switch value
            {
            case "1", "true", "yes", "on": UserDefaults.shared.usesPasteboardDaemonReader = true
            case "0", "false", "no", "off": UserDefaults.shared.usesPasteboardDaemonReader = false
            default: break
            }
            
            NSLog("Pasteboard daemon reader enabled: %d", UserDefaults.shared.usesPasteboardDaemonReader)
            
            #if DEBUG
            if components?.queryItems?.contains(where: { $0.name == "read" && $0.value == "1" }) == true
            {
                NSLog("Reading pasteboard from daemon on demand.")
                ApplicationMonitor.shared.pasteboardMonitor.savePasteboardUsingDaemonReader()
            }
            #endif
            
        case "settings":
            let openURL = URL(string: UIApplication.openSettingsURLString)!
            UIApplication.shared.open(openURL, options: [:], completionHandler: nil)
            
        default:
            break
        }
    }
}

