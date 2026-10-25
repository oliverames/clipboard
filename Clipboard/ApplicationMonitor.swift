//
//  ApplicationMonitor.swift
//  Clipboard
//
//  Created by Riley Testut on 6/27/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import UIKit
import AVFoundation
import UserNotifications
import Combine

import ClipboardKit

/// Writes a small rolling log into the App Group so background behavior can be
/// inspected from a connected Mac without a debugger or Console.
final class Diagnostics
{
    static let shared = Diagnostics()
    
    private let queue = DispatchQueue(label: "com.oliverames.clipboard.diagnostics")
    private let maximumSize = 256 * 1024
    
    private var fileURL: URL?
    {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.oliverames.clipboard")
        
        guard let directory = directory else { return nil }
        
        return directory.appendingPathComponent("clipboard-diagnostics.log")
    }
    
    func log(_ message: String)
    {
        NSLog("Diagnostics: %@", message)
        
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        
        self.queue.async {
            self.append(line, to: self.fileURL)
        }
    }
}

private extension Diagnostics
{
    func append(_ text: String, to fileURL: URL?)
    {
        guard let fileURL = fileURL else { return }
        
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? Int,
           size > self.maximumSize
        {
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        if !FileManager.default.fileExists(atPath: fileURL.path)
        {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        }
        
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    }
}

private extension CFNotificationName
{
    static let altstoreRequestAppState: CFNotificationName = CFNotificationName("com.altstore.RequestAppState.com.rileytestut.Clip" as CFString)
    static let altstoreAppIsRunning: CFNotificationName = CFNotificationName("com.altstore.AppState.Running.com.rileytestut.Clip" as CFString)
}

private let ReceivedApplicationState: @convention(c) (CFNotificationCenter?, UnsafeMutableRawPointer?, CFNotificationName?, UnsafeRawPointer?, CFDictionary?) -> Void =
{ (center, observer, name, object, userInfo) in
    ApplicationMonitor.shared.receivedApplicationStateRequest()
}

class ApplicationMonitor
{
    static let shared = ApplicationMonitor()
    
    let pasteboardMonitor = PasteboardMonitor()
    let locationManager = LocationManager()
    
    private(set) var isMonitoring = false
    
    private var backgroundTaskID: UIBackgroundTaskIdentifier?
}

extension ApplicationMonitor
{
    func start()
    {
        guard !self.isMonitoring else { return }
        self.isMonitoring = true
        
        Diagnostics.shared.log("ApplicationMonitor start")
        
        self.startHeartbeat()
        
        self.pasteboardMonitor.start() { (result) in
            switch result
            {
            case .success:
                self.locationManager.start()
                self.registerForNotifications()
                Diagnostics.shared.log("Monitoring started")
                
            case .failure(let error):
                self.isMonitoring = false
                Diagnostics.shared.log("Monitoring failed: \(error)")
                self.sendNotification(title: NSLocalizedString("Failed to Monitor Clipboard", comment: ""), message: error.localizedDescription)
            }
        }
    }
}

private extension ApplicationMonitor
{
    func registerForNotifications()
    {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, nil, ReceivedApplicationState, CFNotificationName.altstoreRequestAppState.rawValue, nil, .deliverImmediately)
    }
    
    func startHeartbeat()
    {
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            DispatchQueue.main.async {
                Diagnostics.shared.log("Heartbeat; state=\(UIApplication.shared.applicationState.rawValue) previews=\(LinkPreviewStore.shared.cachedPreviewCount)")
            }
            
            self.startHeartbeat()
        }
    }
    
    func sendNotification(title: String, message: String)
    {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

private extension ApplicationMonitor
{
    func receivedApplicationStateRequest()
    {
        guard UIApplication.shared.applicationState != .background else { return }
        
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center!, CFNotificationName(CFNotificationName.altstoreAppIsRunning.rawValue), nil, nil, true)
    }
}
