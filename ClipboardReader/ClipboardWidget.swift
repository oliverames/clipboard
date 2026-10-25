//
//  ClipboardWidget.swift
//  ClipboardReader
//
//  Reads the pasteboard on behalf of the app.
//
//  iOS only hands the general pasteboard to a process the system launches itself, and
//  a widget is one of those: `WidgetCenter.reloadTimelines` makes the system start the
//  widget's process on demand, with no notification involved. That makes a widget the
//  cheapest way to reach the clipboard from the background.
//
//  The widget's job is twofold. Its timeline provider reads the clipboard and stores it,
//  and the widget itself shows how many clippings are in the history.
//

import WidgetKit
import SwiftUI
import UIKit
import CoreData

import ClipboardKit

struct ClipboardProvider: TimelineProvider
{
    func placeholder(in context: Context) -> ClipboardEntry
    {
        ClipboardEntry(date: Date(), count: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (ClipboardEntry) -> Void)
    {
        completion(ClipboardEntry(date: Date(), count: ClipboardStore.shared.clippingCount))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClipboardEntry>) -> Void)
    {
        ClipboardStore.shared.capturePasteboard()

        let entry = ClipboardEntry(date: Date(), count: ClipboardStore.shared.clippingCount)
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct ClipboardEntry: TimelineEntry
{
    let date: Date
    let count: Int
}

struct ClipboardWidgetView: View
{
    var entry: ClipboardEntry

    var body: some View
    {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "doc.on.clipboard")
                .font(.title2)
            Text("\(entry.count)")
                .font(.title2.bold())
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text("clippings")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

@main
struct ClipboardWidgetBundle: WidgetBundle
{
    var body: some Widget
    {
        ClipboardWidget()
    }
}

struct ClipboardWidget: Widget
{
    static let kind = "ClipboardReader"

    var body: some WidgetConfiguration
    {
        StaticConfiguration(kind: Self.kind, provider: ClipboardProvider()) { entry in
            ClipboardWidgetView(entry: entry)
        }
        .configurationDisplayName("Clipboard")
        .description("Keeps the clipboard history up to date.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// Reads the pasteboard and stores it, in a process the system launched for us.
final class ClipboardStore
{
    static let shared = ClipboardStore()

    private var isCapturing = false

    private init()
    {
    }

    /// How many clippings are in the history, for the widget's own display.
    var clippingCount: Int
    {
        let request = PasteboardItem.historyFetchRequest() as NSFetchRequest<PasteboardItem>
        request.fetchLimit = 1

        var count = 0
        let context = DatabaseManager.shared.persistentContainer.viewContext
        context.performAndWait {
            count = (try? context.count(for: request)) ?? 0
        }

        return count
    }

    func capturePasteboard()
    {
        // The system can ask for a timeline more than once in quick succession.
        guard !self.isCapturing else { return }
        self.isCapturing = true

        UserDefaults.shared.registerAppDefaults()

        let pasteboard = UIPasteboard.general
        let changeCount = pasteboard.changeCount

        CaptureLedger.shared.record(.widgetRan, changeCount: changeCount)

        guard !pasteboard.items.isEmpty else
        {
            self.isCapturing = false
            return
        }

        // Idempotent by change count: if this copy was already saved (by a previous
        // widget run, or by the app itself), don't read or write it again.
        guard ChangeCountGate.shouldProcess(changeCount, lastHandled: UserDefaults.shared.lastSavedChangeCount) else
        {
            CaptureLedger.shared.record(.duplicate, changeCount: changeCount, note: "change count already handled")
            self.isCapturing = false
            return
        }

        // The store loads asynchronously. A copy that arrives before it is ready
        // waits for it here rather than being dropped.
        if !DatabaseManager.shared.isStarted
        {
            CaptureLedger.shared.record(.storeWaited, changeCount: changeCount)
        }

        DatabaseManager.shared.persistentContainer.shouldAddStoresAsynchronously = true
        DatabaseManager.shared.prepare { (result) in
            switch result
            {
            case .failure:
                NSLog("ClipboardReader: Failed to prepare the database.")
                CaptureLedger.shared.record(.storeUnavailable, changeCount: changeCount)
                self.isCapturing = false

            case .success:
                DatabaseManager.shared.savePasteboard(location: nil) { (result) in
                    switch result
                    {
                    case .success:
                        UserDefaults.shared.lastSavedChangeCount = changeCount
                        CaptureLedger.shared.record(.saved, changeCount: changeCount)
                    case .failure(PasteboardError.duplicateItem):
                        // Same content as the last clipping: mark this change count
                        // handled so later widget runs stop retrying it.
                        UserDefaults.shared.lastSavedChangeCount = changeCount
                        CaptureLedger.shared.record(.duplicate, changeCount: changeCount)
                    case .failure(let error):
                        CaptureLedger.shared.record(.storeUnavailable, changeCount: changeCount, note: String(describing: error))
                    }
                    NSLog("ClipboardReader: Saved pasteboard: %@", String(describing: result))
                    self.isCapturing = false
                }
            }
        }
    }
}
