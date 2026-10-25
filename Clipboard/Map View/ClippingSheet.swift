//
//  ClippingSheet.swift
//  Clipboard
//
//  Created by Riley Testut on 3/20/24.
//  Copyright © 2024 Riley Testut. All rights reserved.
//

import SwiftUI

import ClipboardKit

@available(iOS 16.4, *)
struct ClippingSheet: View
{
    var pasteboardItem: PasteboardItem

    @Environment(\.dismiss)
    private var dismiss

    @State
    private var copyCount = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                ClippingCell(pasteboardItem: pasteboardItem, lineLimit: 6)
                    .padding(.horizontal)
            }
            .navigationTitle(ClippingKind(pasteboardItem).title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", role: .close, action: cancel)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy", systemImage: "doc.on.doc", action: copy)
                        .buttonStyle(.glassProminent)
                }
            }
        }
        // No custom presentationBackground: the system sheet adopts Liquid Glass (inset at partial detents).
        .presentationDetents([.fraction(0.33), .medium])
        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.33)))
        .sensoryFeedback(.success, trigger: self.copyCount)
    }
}

@available(iOS 16.4, *)
private extension ClippingSheet
{
    func copy()
    {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, .ignoreNextPasteboardChange, nil, nil, true)

        UIPasteboard.general.copy(self.pasteboardItem)
        self.copyCount += 1

        // Let the haptic land before the sheet goes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.dismiss()
        }
    }

    func cancel()
    {
        self.dismiss()
    }
}
