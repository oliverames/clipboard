//
//  ClipboardWidgetPreviews.swift
//  ClipboardReader
//
//  Previews live apart from the widget's capture code, so Xcode's preview build only
//  re-compiles the view side.
//

import SwiftUI
import WidgetKit

#Preview("Small", as: .systemSmall) {
    ClipboardWidget()
} timeline: {
    ClipboardEntry(date: .now, count: 24)
}

#Preview("Medium", as: .systemMedium) {
    ClipboardWidget()
} timeline: {
    ClipboardEntry(date: .now.addingTimeInterval(-300), count: 24)
}
