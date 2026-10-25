//
//  UserDefaults+App.swift
//  Clipboard
//
//  Created by Riley Testut on 6/14/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import Foundation

import Roxas

@objc public enum HistoryLimit: Int, CaseIterable
{
    case _10 = 10
    case _25 = 25
    case _50 = 50
    case _100 = 100
}

public extension UserDefaults
{
    static let shared: UserDefaults = {
        guard let appGroup = Bundle.main.appGroups.first else { return .standard }
        
        let sharedUserDefaults = UserDefaults(suiteName: appGroup)!
        return sharedUserDefaults
    }()
    
    @NSManaged var historyLimit: HistoryLimit
    @NSManaged var maximumClippingSize: Int
    @NSManaged var showLocationIcon: Bool
    @NSManaged var generateLinkPreviews: Bool
    @NSManaged var allowsShortcutsHistory: Bool
    @NSManaged var hasCompletedOnboarding: Bool
    
    /// Reads the general pasteboard from the private pasteboard daemon so
    /// background changes can be saved without tapping a notification.
    @NSManaged var usesPasteboardDaemonReader: Bool

    /// Records a content-free ledger of capture events into the App Group so the
    /// background pipeline can be measured. See `CaptureLedger`.
    @NSManaged var captureDiagnosticsEnabled: Bool

    /// The pasteboard change count of the most recently saved clipping, shared
    /// across the app and its extensions so a change count is only saved once.
    /// A value of 0 means nothing has been saved yet.
    @NSManaged var lastSavedChangeCount: Int
}

public extension UserDefaults
{
    func registerAppDefaults()
    {
        // Capture diagnostics default on for development and device measurement,
        // off for a shipped release so a shipped build keeps no ledger.
        #if DEBUG
        let captureDiagnosticsDefault = true
        #else
        let captureDiagnosticsDefault = false
        #endif

        self.register(defaults: [
            #keyPath(UserDefaults.historyLimit): HistoryLimit._25.rawValue,
            #keyPath(UserDefaults.maximumClippingSize): 10 * .bytesPerMegabyte,
            #keyPath(UserDefaults.showLocationIcon): true,
            #keyPath(UserDefaults.generateLinkPreviews): true,
            #keyPath(UserDefaults.usesPasteboardDaemonReader): true,
            #keyPath(UserDefaults.captureDiagnosticsEnabled): captureDiagnosticsDefault
        ])
    }
}
