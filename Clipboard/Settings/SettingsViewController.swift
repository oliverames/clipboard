//
//  SettingsViewController.swift
//  Clipboard
//
//  Created by Riley Testut on 6/14/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import UIKit
import SwiftUI
import CoreLocation

import ClipboardKit

extension Notification.Name
{
    /// Posted when a setting that changes how the history draws, such as location icons, changes.
    static let settingsDidChange = Notification.Name("SettingsDidChangeNotification")
}

class SettingsViewController: ReservedRegionHostingController<AnyView>
{
    /// Called when the person asks to see the setup steps again.
    var onShowSetupGuide: (() -> Void)?

    init()
    {
        super.init(rootView: AnyView(EmptyView()))

        self.rootView = AnyView(SettingsView(onShowSetupGuide: { [weak self] in
            self?.onShowSetupGuide?()
        }))
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder)
    {
        fatalError("init(coder:) has not been implemented")
    }
}

struct SettingsView: View
{
    var onShowSetupGuide: () -> Void

    @Environment(\.dismiss)
    private var dismiss

    @State private var historyLimit = UserDefaults.shared.historyLimit
    @State private var showLocationIcon = UserDefaults.shared.showLocationIcon
    @State private var generateLinkPreviews = UserDefaults.shared.generateLinkPreviews
    @State private var allowsShortcutsHistory = UserDefaults.shared.allowsShortcutsHistory
    @State private var locationStatus = CLLocationManager().authorizationStatus

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Keep", selection: self.$historyLimit) {
                        ForEach(HistoryLimit.allCases, id: \.self) { limit in
                            Text("Last \(limit.rawValue) Clippings").tag(limit)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("History")
                } footer: {
                    Text("Favorites and clippings in a list are always kept, however long the history.")
                }

                Section {
                    LabeledContent {
                        Text(self.locationStatusText)
                            .foregroundStyle(self.locationStatus == .authorizedAlways ? .green : .orange)
                    } label: {
                        Label("Background Capture", systemImage: "location.fill")
                    }

                    if self.locationStatus != .authorizedAlways
                    {
                        Button("Open Settings", systemImage: "gear", action: self.openSystemSettings)
                    }

                    Toggle(isOn: self.$showLocationIcon) {
                        Label("Show Location Icons", systemImage: "mappin.and.ellipse")
                    }
                } header: {
                    Text("Capture")
                } footer: {
                    Text("Always location access keeps Clipboard watching the clipboard in the background. Your location only tags clippings and never leaves this iPhone.")
                }

                Section {
                    Toggle(isOn: self.$generateLinkPreviews) {
                        Label("Link Previews", systemImage: "link")
                    }
                } footer: {
                    Text("Downloads each copied page's title and icon. Opening a link this way can count as a visit, or use up a one-time link.")
                }

                Section {
                    Toggle(isOn: self.$allowsShortcutsHistory) {
                        Label("Allow Shortcuts Access", systemImage: "square.2.layers.3d")
                    }
                } footer: {
                    Text("Lets the Get Latest Clipping action return your newest text clipping. It only works while your iPhone is unlocked.")
                }

                // Diagnostics entry point: a Section with a NavigationLink belongs here, above About.

                Section {
                    Button("Setup Guide", systemImage: "list.number", action: self.onShowSetupGuide)
                    Link(destination: URL(string: "https://github.com/rileytestut/Clip")!) {
                        Label("Based on Clip by Riley Testut", systemImage: "heart")
                    }
                } footer: {
                    Text(self.versionText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark", role: .confirm) {
                        self.dismiss()
                    }
                }
            }
        }
        .onChange(of: self.historyLimit) { _, value in
            UserDefaults.shared.historyLimit = value
            Haptics.selection()
        }
        .onChange(of: self.showLocationIcon) { _, value in
            UserDefaults.shared.showLocationIcon = value
            NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        }
        .onChange(of: self.generateLinkPreviews) { _, value in
            UserDefaults.shared.generateLinkPreviews = value
        }
        .onChange(of: self.allowsShortcutsHistory) { _, value in
            UserDefaults.shared.allowsShortcutsHistory = value
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            self.locationStatus = CLLocationManager().authorizationStatus
        }
    }

    private var locationStatusText: String {
        switch self.locationStatus
        {
        case .authorizedAlways: return NSLocalizedString("On", comment: "")
        case .authorizedWhenInUse: return NSLocalizedString("Needs Always", comment: "")
        case .denied, .restricted: return NSLocalizedString("Off", comment: "")
        default: return NSLocalizedString("Not Set Up", comment: "")
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return String(format: NSLocalizedString("Clipboard %@ (%@)", comment: "Clipboard [version] ([build])"), version, build)
    }

    private func openSystemSettings()
    {
        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
    }
}
