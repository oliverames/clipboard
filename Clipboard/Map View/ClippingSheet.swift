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
    
    var body: some View {
        NavigationStack {
            ClippingCell(pasteboardItem: pasteboardItem)
                .padding()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Copy", action: copy)
                    }
                    
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: cancel)
                    }
                }
        }
        // No custom presentationBackground: the system sheet adopts Liquid Glass (inset at partial detents).
        .presentationDetents([.fraction(0.33)])
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
        
        self.dismiss()
    }
    
    func cancel()
    {
        self.dismiss()
    }
}
