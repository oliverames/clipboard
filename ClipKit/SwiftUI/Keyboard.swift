//
//  Keyboard.swift
//  ClipKit
//
//  Created by Riley Testut on 5/25/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import SwiftUI
import CoreData
import UIKit

import Roxas

@objc
private protocol RSTApplication: AnyObject
{
    @objc(openURL:options:completionHandler:)
    func open(_ url: URL, options: [UIApplication.OpenExternalURLOptionsKey : Any], completionHandler completion: (@MainActor @Sendable (Bool) -> Void)?)
}

public struct Keyboard: View
{
    private let inputViewController: UIInputViewController?
    private let needsInputModeSwitchKey: Bool
    private let hasFullAccess: Bool

    @FetchRequest(fetchRequest: PasteboardItem.historyFetchRequest())
    private var pasteboardItems: FetchedResults<PasteboardItem>

    @Environment(\.horizontalSizeClass)
    private var horizontalSizeClass

    @ScaledMetric(relativeTo: .title2)
    private var switchKeyboardButtonSize = 44.0

    public init(inputViewController: UIInputViewController?,
                needsInputModeSwitchKey: Bool? = nil,
                hasFullAccess: Bool? = nil)
    {
        self.inputViewController = inputViewController
        self.needsInputModeSwitchKey = needsInputModeSwitchKey ?? inputViewController?.needsInputModeSwitchKey ?? false
        self.hasFullAccess = hasFullAccess ?? inputViewController?.hasFullAccess ?? true
    }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            if !self.hasFullAccess
            {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Text("Full Access Disabled")
                            .font(.title3.weight(.semibold))

                        Text("Allow Full Access for this keyboard in Settings to access saved clippings.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Button(action: self.openSettings) {
                        Text("Open Settings")
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: self.pasteUUID) {
                        Text("Paste Random UUID")
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
            else if self.pasteboardItems.isEmpty
            {
                VStack(spacing: 8) {
                    Text("No Clippings")
                        .font(.title3.weight(.semibold))

                    Text("Items that you've copied to the clipboard will appear here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
            else
            {
                List(self.pasteboardItems, id: \.objectID) { (pasteboardItem) in
                    HStack(spacing: 8) {
                        Button(action: { self.paste(pasteboardItem) }) {
                            ClippingCell(pasteboardItem: pasteboardItem)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button(action: { self.copy(pasteboardItem) }) {
                            Image(systemName: "doc.on.doc")
                                .font(.body)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Copy")
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // Only the scrolling list extends under the bottom edge. Horizontal safe area stays honored
                // so row content (including the trailing Copy button) clears any reserved region on iPhone Duo.
                .ignoresSafeArea(.container, edges: .bottom)
            }

            if self.needsInputModeSwitchKey
            {
                let margin = (self.horizontalSizeClass == .regular) ? 16.0 : 8.0

                // Floating control over scrolling content, so Liquid Glass applies. Placed with padding inside
                // the safe area (not offset from the container edge) so it clears leading/bottom reserved regions.
                SwitchKeyboardButton(inputViewController: self.inputViewController,
                                     configuration: .init(textStyle: .title2))
                    .frame(width: self.switchKeyboardButtonSize, height: self.switchKeyboardButtonSize)
                    .glassEffect(.regular, in: .circle)
                    .padding(.leading, margin)
                    .padding(.bottom, margin)
            }
        }
    }
}

private extension Keyboard
{
    func paste(_ pasteboardItem: PasteboardItem)
    {
        guard let text = pasteboardItem.contentText else { return }

        self.copy(pasteboardItem)

        self.paste(text)
    }

    func copy(_ pasteboardItem: PasteboardItem)
    {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, .ignoreNextPasteboardChange, nil, nil, true)

        UIPasteboard.general.copy(pasteboardItem)
    }

    func pasteUUID()
    {
        let uuid = UUID().uuidString
        self.paste(uuid)
    }

    func paste(_ text: String)
    {
        self.inputViewController?.textDocumentProxy.insertText(text)
        self.inputViewController?.inputView?.playInputClick()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.inputViewController?.advanceToNextInputMode()
        }
    }

    func openSettings()
    {
        // NSExtensionContext.openURL() can only be called from Today extensions.
        // As a workaround, we can just call UIApplication.openURL(),
        // but we can't call it directly because it's marked as unavailable for extensions.
        guard
            let application = (UIApplication.self as AnyObject).value(forKey: "sharedApplication") as? UIApplication
        else { return }

        // UIApplication.openSettingsURLString doesn't work from keyboard extension,
        // so instead we open Clipboard which will then open Settings.
        let openURL = URL(string: "clipboard://settings")!

        let tempApp = unsafeBitCast(application, to: RSTApplication.self)
        tempApp.open(openURL, options: [:], completionHandler: nil)
    }
}

struct Keyboard_Previews: PreviewProvider
{
    static var previews: some View
    {
        Preview.prepare()

        let context = DatabaseManager.shared.persistentContainer.viewContext
        let date = Date().addingTimeInterval(-1 * 60 * 60)

        _ = PasteboardItem.make(item: "Hello SwiftUI!" as NSString, date: date, context: context)
        _ = PasteboardItem.make(item: NSURL(string: "https://rileytestut.com")!, date: date, context: context)
        _ = PasteboardItem.make(item: "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum." as NSString, date: date, context: context)

        return Group {
            Keyboard(inputViewController: nil, needsInputModeSwitchKey: true)
            Keyboard(inputViewController: nil, needsInputModeSwitchKey: true, hasFullAccess: false)
        }
        .environment(\.managedObjectContext, context)
        .previewLayout(.fixed(width: 375, height: 500))
    }
}
