//
//  PasteboardMonitor.swift
//  Clip
//
//  Created by Riley Testut on 6/11/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import UIKit
import AVFoundation
import UserNotifications
import CoreLocation
import WidgetKit

import ClipboardKit
import Roxas

private let PasteboardMonitorDidChangePasteboard: @convention(c) (CFNotificationCenter?, UnsafeMutableRawPointer?, CFNotificationName?, UnsafeRawPointer?, CFDictionary?) -> Void =
{ (center, observer, name, object, userInfo) in
    ApplicationMonitor.shared.pasteboardMonitor.didChangePasteboard()
}

private let PasteboardMonitorIgnoreNextPasteboardChange: @convention(c) (CFNotificationCenter?, UnsafeMutableRawPointer?, CFNotificationName?, UnsafeRawPointer?, CFDictionary?) -> Void =
{ (center, observer, name, object, userInfo) in
    ApplicationMonitor.shared.pasteboardMonitor.ignoreNextPasteboardChange = true
}

class PasteboardMonitor
{
    /// Delays, in seconds, between retries of a failed daemon read.
    private static let daemonReadRetryDelays: [TimeInterval] = [1, 3]

    private(set) var isStarted = false
    fileprivate var ignoreNextPasteboardChange = false

    /// How long to wait before checking whether the widget saved the pasteboard.
    private static let widgetCheckDelay: TimeInterval = 20

    /// How many times to ask the widget before giving up on a copy.
    private static let widgetMaximumAttempts = 9

    /// Whether a widget capture is currently in flight.
    private var isTriggerRunning = false
    private var triggerAttempts = 0
    private var triggerStartDate: Date?
    /// The pasteboard change count the current widget trigger is trying to capture.
    private var triggerChangeCount = 0

    private let feedbackGenerator = UINotificationFeedbackGenerator()
}

extension PasteboardMonitor
{
    func start(completionHandler: @escaping (Result<Void, Error>) -> Void)
    {
        guard !self.isStarted else { return }
        self.isStarted = true

        self.registerForNotifications()
        completionHandler(.success(()))
    }
}

extension PasteboardMonitor
{
    /// Reads the pasteboard from the daemon, which works while the app is in the background.
    func savePasteboardUsingDaemonReader()
    {
        let location = ApplicationMonitor.shared.locationManager.location
        let reader = PasteboardDaemonReader()

        self.readFromDaemon(reader: reader, attempt: 0, location: location)
    }

    private func readFromDaemon(reader: PasteboardDaemonReader, attempt: Int, location: CLLocation?)
    {
        Diagnostics.shared.log("Daemon read start; attempt=\(attempt) state=\(UIApplication.shared.applicationState.rawValue)")

        reader.readGeneralPasteboard { (snapshots, error) in
            #if DEBUG
            self.logDaemonComparison(snapshots: snapshots, error: error)
            #endif

            let types = snapshots?.map { $0.keys.sorted() } ?? []
            Diagnostics.shared.log("Daemon read finished; attempt=\(attempt) items=\(snapshots?.count ?? 0) types=\(types) error=\(error.map { String(describing: $0) } ?? "none")")

            // If the private path is unavailable, keep the existing UIPasteboard behavior as a fallback.
            guard let snapshots = snapshots, !snapshots.isEmpty else {
                // The pasteboard is sometimes briefly unavailable right after it changes, so retry
                // a few times before giving up on it.
                if attempt < Self.daemonReadRetryDelays.count
                {
                    let delay = Self.daemonReadRetryDelays[attempt]
                    Diagnostics.shared.log("Daemon read retrying in \(delay)s")
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        self.readFromDaemon(reader: reader, attempt: attempt + 1, location: location)
                    }
                    return
                }

                NSLog("Pasteboard daemon read failed, falling back to UIPasteboard: %@", error?.localizedDescription ?? "no items")
                self.savePasteboardUsingUIPasteboard()
                return
            }

            let changeCount = UIPasteboard.general.changeCount
            DatabaseManager.shared.savePasteboard(snapshot: snapshots, location: location) { (result) in
                switch result
                {
                case .success:
                    if changeCount != 0 { UserDefaults.shared.lastSavedChangeCount = changeCount }
                    CaptureLedger.shared.record(.saved, changeCount: changeCount)
                    Diagnostics.shared.log("Daemon snapshot saved")
                case .failure(PasteboardError.duplicateItem):
                    if changeCount != 0 { UserDefaults.shared.lastSavedChangeCount = changeCount }
                    CaptureLedger.shared.record(.duplicate, changeCount: changeCount)
                    Diagnostics.shared.log("Daemon snapshot was a duplicate")
                case .failure(let error):
                    NSLog("Failed to save pasteboard daemon snapshot, falling back to UIPasteboard: %@", error.localizedDescription)
                    Diagnostics.shared.log("Daemon snapshot save failed: \(error)")
                    self.savePasteboardUsingUIPasteboard()
                }
            }
        }
    }

    func savePasteboardUsingUIPasteboard()
    {
        Diagnostics.shared.log("UIPasteboard read start; state=\(UIApplication.shared.applicationState.rawValue)")
        
        let pasteboard = UIPasteboard.general
        let changeCount = pasteboard.changeCount
        Diagnostics.shared.log("UIPasteboard raw: changeCount=\(pasteboard.changeCount) types=\(pasteboard.types) items=\(pasteboard.items.count) stringLength=\(pasteboard.string?.count ?? 0)")

        DatabaseManager.shared.savePasteboard(location: ApplicationMonitor.shared.locationManager.location) { (result) in
            switch result
            {
            case .success:
                if changeCount != 0 { UserDefaults.shared.lastSavedChangeCount = changeCount }
                CaptureLedger.shared.record(.saved, changeCount: changeCount)
                Diagnostics.shared.log("UIPasteboard snapshot saved")
            case .failure(PasteboardError.duplicateItem):
                if changeCount != 0 { UserDefaults.shared.lastSavedChangeCount = changeCount }
                CaptureLedger.shared.record(.duplicate, changeCount: changeCount)
                Diagnostics.shared.log("UIPasteboard snapshot was a duplicate")
            case .failure(let error):
                Diagnostics.shared.log("UIPasteboard snapshot save failed: \(error)")
                self.presentChangeNotification()
            }
        }
    }
}

private extension PasteboardMonitor
{
    func registerForNotifications()
    {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, nil, PasteboardMonitorDidChangePasteboard, CFNotificationName.didChangePasteboard.rawValue, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, nil, PasteboardMonitorIgnoreNextPasteboardChange, CFNotificationName.ignoreNextPasteboardChange.rawValue, nil, .deliverImmediately)

        #if !targetEnvironment(simulator)
        let beginListeningSelector = ["Notifications", "Change", "Pasteboard", "To", "Listening", "begin"].reversed().joined()

        let className = ["Connection", "Server", "PB"].reversed().joined()

        let PBServerConnection = NSClassFromString(className) as AnyObject
        _ = PBServerConnection.perform(NSSelectorFromString(beginListeningSelector))
        #endif

        let changedNotification = ["changed", "pasteboard", "apple", "com"].reversed().joined(separator: ".")
        NotificationCenter.default.addObserver(self, selector: #selector(PasteboardMonitor.pasteboardDidUpdate), name: Notification.Name(changedNotification), object: nil)
    }

    @objc func pasteboardDidUpdate()
    {
        // The change count is readable even while backgrounded; only the contents are withheld.
        let changeCount = UIPasteboard.general.changeCount
        Diagnostics.shared.log("Pasteboard change notification; state=\(UIApplication.shared.applicationState.rawValue) ignore=\(self.ignoreNextPasteboardChange)")
        CaptureLedger.shared.record(.changeHeard, changeCount: changeCount)

        guard !self.ignoreNextPasteboardChange else {
            self.ignoreNextPasteboardChange = false
            return
        }

        DispatchQueue.main.async {
            let applicationState = UIApplication.shared.applicationState

            if applicationState == .active
            {
                // Don't save or notify for items copied from within Clipboard.
                guard !UIPasteboard.general.contains(pasteboardTypes: [UTI.clipping]) else { return }
            }

            if !DatabaseManager.shared.isStarted
            {
                CaptureLedger.shared.record(.storeWaited, changeCount: changeCount)
            }

            // The store loads asynchronously, so a copy that arrives during launch waits for it.
            DatabaseManager.shared.prepare { (preparation) in
                DispatchQueue.main.async {
                    guard case .success = preparation else {
                        CaptureLedger.shared.record(.storeUnavailable, changeCount: changeCount)
                        return self.presentChangeNotification()
                    }

                    // While the app isn't active the system won't hand over the pasteboard,
                    // so ask a widget extension to read it on our behalf. The system launches
                    // the widget's process on demand, and no notification is involved.
                    if applicationState != .active
                    {
                        self.presentWidgetTrigger()
                        return
                    }

                    if UserDefaults.shared.usesPasteboardDaemonReader && PasteboardDaemonReader.isAvailable()
                    {
                        self.savePasteboardUsingDaemonReader()
                    }
                    else
                    {
                        self.savePasteboardUsingUIPasteboard()
                    }
                }
            }
        }
    }

    #if DEBUG
    func logDaemonComparison(snapshots: [[String: Data]]?, error: Error?)
    {
        let daemonTypes = snapshots?.map { $0.keys.sorted() } ?? []
        let pasteboard = UIPasteboard.general

        NSLog("Pasteboard daemon read: %@ types: %@", error.map { "error: \($0)" } ?? "success", daemonTypes.description)
        NSLog("UIPasteboard comparison: changeCount: %ld types: %@ hasStrings: %@ hasImages: %@ hasURLs: %@ applicationState: %ld",
              pasteboard.changeCount,
              pasteboard.types.description,
              String(pasteboard.hasStrings),
              String(pasteboard.hasImages),
              String(pasteboard.hasURLs),
              UIApplication.shared.applicationState.rawValue)
    }
    #endif

    /// Asks the system to start the widget extension, which reads the pasteboard and
    /// saves it. The system launches the widget's process on demand, so this works
    /// without a notification and without any interaction.
    ///
    /// The system throttles how often it will start a widget, so the request is made
    /// again until the store shows the copy was saved.
    func presentWidgetTrigger()
    {
        let changeCount = UIPasteboard.general.changeCount

        // If a trigger is already in flight and a newer copy arrives, keep the same
        // loop but aim it at the newest change count and give it a fresh deadline.
        // The widget always reads whatever is current, so the newest copy is the one
        // that gets saved; this just stops an early give-up from dropping it.
        guard !self.isTriggerRunning else {
            Diagnostics.shared.log("Widget trigger already running; coalescing to changeCount=\(changeCount).")
            if changeCount != self.triggerChangeCount
            {
                self.triggerChangeCount = changeCount
                self.triggerAttempts = 0
                self.triggerStartDate = Date()
            }
            return
        }

        self.isTriggerRunning = true
        self.triggerAttempts = 0
        self.triggerStartDate = Date()
        self.triggerChangeCount = changeCount

        self.askWidgetToCapture()
    }

    private func askWidgetToCapture()
    {
        WidgetCenter.shared.reloadTimelines(ofKind: "ClipboardReader")

        Diagnostics.shared.log("Asked the widget to capture the pasteboard; attempt=\(self.triggerAttempts + 1)")
        CaptureLedger.shared.record(.reloadRequested, changeCount: self.triggerChangeCount, attempt: self.triggerAttempts + 1)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.widgetCheckDelay) {
            guard self.isTriggerRunning, let startDate = self.triggerStartDate else { return }

            // The widget marks the change count it saved, so prefer that signal; fall
            // back to "any clipping saved since we started" for copies with no count.
            let savedChangeCount = UserDefaults.shared.lastSavedChangeCount
            let savedByChangeCount = self.triggerChangeCount != 0 && savedChangeCount == self.triggerChangeCount

            DatabaseManager.shared.hasItemSaved(after: startDate) { (wasSaved) in
                DispatchQueue.main.async {
                    guard self.isTriggerRunning else { return }

                    guard !(wasSaved || savedByChangeCount) else {
                        Diagnostics.shared.log("The widget saved the pasteboard.")
                        self.isTriggerRunning = false
                        return
                    }

                    guard self.triggerAttempts < Self.widgetMaximumAttempts else {
                        Diagnostics.shared.log("The widget never saved the pasteboard.")
                        CaptureLedger.shared.record(.missed, changeCount: self.triggerChangeCount, attempt: self.triggerAttempts + 1)
                        self.isTriggerRunning = false
                        return
                    }

                    self.triggerAttempts += 1
                    self.askWidgetToCapture()
                }
            }
        }
    }

    /// Only used when the store couldn't be opened, which means the copy can't be saved
    /// until the app is running again.
    func presentChangeNotification()
    {
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = UNNotificationCategory.clipboardReaderIdentifier
        content.title = NSLocalizedString("Clipboard Changed", comment: "")
        content.body = NSLocalizedString("Couldn't save to Clipboard.", comment: "")

        if let location = ApplicationMonitor.shared.locationManager.location
        {
            content.userInfo = [
                UNNotification.latitudeUserInfoKey: location.coordinate.latitude,
                UNNotification.longitudeUserInfoKey: location.coordinate.longitude
            ]
        }

        let request = UNNotificationRequest(identifier: "ClipboardChanged", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { (error) in
            if let error = error {
                print(error)
            }
        }
    }
}

private extension PasteboardMonitor
{
    func didChangePasteboard()
    {
        DatabaseManager.shared.refresh()

        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["ClipboardChanged"])
    }
}
