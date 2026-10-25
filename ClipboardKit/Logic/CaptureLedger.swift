//
//  CaptureLedger.swift
//  ClipboardKit
//
//  A small, shared, debug-only ledger of background-capture events, written into
//  the App Group so the app, the widget extension, and the keyboard all append to
//  the same file. It records what happened and when — a pasteboard change was
//  heard, a widget reload was asked for, the widget ran, a clipping was saved, or
//  a copy was missed — so the capture pipeline can be measured instead of guessed
//  at. It never records clipboard contents: only the change count, the event, and
//  which process logged it. (ac158ef removed content logging deliberately; keep it
//  out of here too.)
//

import Foundation

/// A single kind of thing that can happen in the capture pipeline.
public enum CaptureEvent: String, Codable, CaseIterable
{
    /// The app heard the pasteboard change (CFNotification / PBServerConnection listener).
    case changeHeard
    /// The app asked the system to run the widget (WidgetCenter.reloadTimelines).
    case reloadRequested
    /// The widget extension's timeline provider actually ran.
    case widgetRan
    /// A clipping was written to the store.
    case saved
    /// The current change count was already saved, so nothing was written.
    case duplicate
    /// The store wasn't ready yet, so the copy waited for it.
    case storeWaited
    /// The store never became ready, so the copy couldn't be saved here.
    case storeUnavailable
    /// The app gave up asking the widget without a save landing.
    case missed
    /// The app read the pasteboard itself on returning to the foreground.
    case foregroundRead
}

/// Which process wrote a ledger entry.
public enum CaptureSource: String, Codable
{
    case app
    case widget
    case keyboard
    case other

    public static var current: CaptureSource
    {
        guard let identifier = Bundle.main.bundleIdentifier else { return .other }
        if identifier.hasSuffix(".ClipboardReader") { return .widget }
        if identifier.hasSuffix(".ClipboardKeyboard") { return .keyboard }
        // The app's own bundle id has no extension suffix.
        if identifier.contains("ClipboardReader") { return .widget }
        if identifier.contains("ClipboardKeyboard") { return .keyboard }
        return .app
    }
}

/// One line in the ledger.
public struct CaptureLedgerEntry: Codable
{
    public let date: Date
    public let source: CaptureSource
    public let event: CaptureEvent
    /// The pasteboard change count this entry is about, when known. The change
    /// count is the join key that lets a reload be matched to the save it caused.
    public let changeCount: Int?
    /// Which retry this was, for reload requests.
    public let attempt: Int?
    /// A short, content-free note (e.g. an error description or a type-identifier list).
    public let note: String?

    public init(date: Date = Date(), source: CaptureSource = .current, event: CaptureEvent, changeCount: Int? = nil, attempt: Int? = nil, note: String? = nil)
    {
        self.date = date
        self.source = source
        self.event = event
        self.changeCount = changeCount
        self.attempt = attempt
        self.note = note
    }
}

/// Aggregate numbers computed from the ledger, for the Diagnostics screen.
public struct CaptureStats
{
    public var changesHeard = 0
    public var reloadsRequested = 0
    public var widgetRuns = 0
    public var saves = 0
    public var duplicates = 0
    public var misses = 0
    public var storeWaits = 0
    public var storeUnavailables = 0

    /// Distinct change counts the app noticed (heard or asked the widget about).
    public var changeCountsSeen = 0
    /// Distinct change counts that produced a save.
    public var changeCountsSaved = 0

    public var firstEventDate: Date?
    public var lastEventDate: Date?

    /// Fraction of seen change counts that never produced a save, 0...1.
    /// Returns nil when nothing has been seen yet.
    public var missRate: Double?
    {
        guard self.changeCountsSeen > 0 else { return nil }
        let saved = min(self.changeCountsSaved, self.changeCountsSeen)
        return 1.0 - (Double(saved) / Double(self.changeCountsSeen))
    }

    public var captureRate: Double?
    {
        guard let missRate = self.missRate else { return nil }
        return 1.0 - missRate
    }

    public init() {}
}

/// Decides whether a pasteboard change count still needs handling, so the widget's
/// read is idempotent: if the system starts the widget more than once for the same
/// copy, only the first run does work. A change count of 0 is treated as "unknown"
/// and always processed (the pasteboard reports 0 before anything is read).
public enum ChangeCountGate
{
    public static func shouldProcess(_ changeCount: Int, lastHandled: Int) -> Bool
    {
        guard changeCount != 0 else { return true }
        return changeCount != lastHandled
    }
}

public final class CaptureLedger
{
    public static let shared = CaptureLedger()

    private let queue = DispatchQueue(label: "com.oliverames.clipboard.capture-ledger")
    private let coordinator = NSFileCoordinator()
    private let maximumSize: Int
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    /// Where the ledger file lives. Nil in the default instance means "derive from the
    /// App Group container at use time"; tests inject a temporary directory instead.
    private let directoryOverride: URL?
    private let isEnabledOverride: Bool?

    private init()
    {
        self.directoryOverride = nil
        self.isEnabledOverride = nil
        self.maximumSize = 128 * 1024

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        self.decoder.dateDecodingStrategy = .iso8601
    }

    /// Dedicated instance for tests: a fixed directory, an explicit enabled flag, and a
    /// small size cap so trimming can be exercised without writing megabytes.
    public init(directory: URL, isEnabled: Bool = true, maximumSize: Int = 128 * 1024)
    {
        self.directoryOverride = directory
        self.isEnabledOverride = isEnabled
        self.maximumSize = maximumSize

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        self.decoder.dateDecodingStrategy = .iso8601
    }

    /// Whether capture logging is on. Off by default in release builds so a shipped
    /// build keeps nothing; on by default for development and device measurement.
    public var isEnabled: Bool
    {
        if let isEnabledOverride = self.isEnabledOverride { return isEnabledOverride }
        return UserDefaults.shared.captureDiagnosticsEnabled
    }

    private var fileURL: URL?
    {
        if let directoryOverride = self.directoryOverride
        {
            return directoryOverride.appendingPathComponent("capture-ledger.jsonl")
        }

        guard
            let appGroup = Bundle.main.appGroups.first,
            let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        else { return nil }

        return container.appendingPathComponent("capture-ledger.jsonl")
    }

    /// Blocks until all queued writes have been flushed. For tests only.
    public func flushForTesting()
    {
        self.queue.sync {}
    }

    /// The current ledger file, if one exists. Exposed so a device test can pull it.
    public var ledgerFileURL: URL?
    {
        guard let fileURL = self.fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return fileURL
    }

    /// Copies the ledger to `destination`, overwriting it. Used by the device test to
    /// stage the ledger where `devicectl` can copy it off the phone.
    @discardableResult
    public func exportCopy(to destination: URL) -> Bool
    {
        guard let fileURL = self.ledgerFileURL else { return false }
        self.queue.sync {}
        try? FileManager.default.removeItem(at: destination)
        do { try FileManager.default.copyItem(at: fileURL, to: destination); return true }
        catch { return false }
    }

    /// Append one event. Cheap and fire-and-forget; safe to call from any process.
    public func record(_ event: CaptureEvent, changeCount: Int? = nil, attempt: Int? = nil, note: String? = nil)
    {
        guard self.isEnabled else { return }

        let entry = CaptureLedgerEntry(source: .current, event: event, changeCount: changeCount, attempt: attempt, note: note)

        self.queue.async {
            self.append(entry)
        }
    }

    private func append(_ entry: CaptureLedgerEntry)
    {
        guard let fileURL = self.fileURL else { return }
        guard let line = try? self.encoder.encode(entry), let newline = "\n".data(using: .utf8) else { return }

        var coordinationError: NSError?
        self.coordinator.coordinate(writingItemAt: fileURL, options: [], error: &coordinationError) { (url) in
            var existing = (try? Data(contentsOf: url)) ?? Data()

            // Keep the file bounded by dropping whole lines from the front.
            if existing.count + line.count + 1 > self.maximumSize
            {
                existing = self.trimmed(existing, toAtMost: self.maximumSize / 2)
            }

            existing.append(line)
            existing.append(newline)

            try? existing.write(to: url, options: .atomic)
        }
    }

    /// Drops whole leading lines until the data is at most `limit` bytes.
    private func trimmed(_ data: Data, toAtMost limit: Int) -> Data
    {
        guard data.count > limit else { return data }

        let newline = UInt8(ascii: "\n")
        var start = data.count - limit
        // Advance to just past the next newline so we never keep a partial line.
        while start < data.count, data[data.startIndex + start] != newline
        {
            start += 1
        }
        if start < data.count { start += 1 }
        guard start < data.count else { return Data() }

        return data.subdata(in: (data.startIndex + start) ..< data.endIndex)
    }

    /// Parse the ledger into entries, oldest first. Reads under coordination.
    public func loadEntries() -> [CaptureLedgerEntry]
    {
        guard let fileURL = self.fileURL else { return [] }

        var data = Data()
        var coordinationError: NSError?
        self.coordinator.coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { (url) in
            data = (try? Data(contentsOf: url)) ?? Data()
        }

        guard !data.isEmpty else { return [] }

        var entries = [CaptureLedgerEntry]()
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty
        {
            if let entry = try? self.decoder.decode(CaptureLedgerEntry.self, from: Data(line))
            {
                entries.append(entry)
            }
        }
        return entries
    }

    /// Compute aggregate statistics from the current ledger.
    public func loadStats() -> CaptureStats
    {
        return Self.stats(from: self.loadEntries())
    }

    /// Pure, testable aggregation from a list of entries.
    public static func stats(from entries: [CaptureLedgerEntry]) -> CaptureStats
    {
        var stats = CaptureStats()
        var seen = Set<Int>()
        var saved = Set<Int>()

        for entry in entries
        {
            if stats.firstEventDate == nil { stats.firstEventDate = entry.date }
            stats.lastEventDate = entry.date

            switch entry.event
            {
            case .changeHeard:
                stats.changesHeard += 1
                if let changeCount = entry.changeCount { seen.insert(changeCount) }
            case .reloadRequested:
                stats.reloadsRequested += 1
                if let changeCount = entry.changeCount { seen.insert(changeCount) }
            case .widgetRan:
                stats.widgetRuns += 1
                if let changeCount = entry.changeCount { seen.insert(changeCount) }
            case .saved:
                stats.saves += 1
                if let changeCount = entry.changeCount
                {
                    seen.insert(changeCount)
                    saved.insert(changeCount)
                }
            case .duplicate:
                stats.duplicates += 1
            case .missed:
                stats.misses += 1
            case .storeWaited:
                stats.storeWaits += 1
            case .storeUnavailable:
                stats.storeUnavailables += 1
            case .foregroundRead:
                break
            }
        }

        stats.changeCountsSeen = seen.count
        stats.changeCountsSaved = saved.intersection(seen).count
        return stats
    }

    /// The most recent `limit` entries, newest first, for display.
    public func recentEntries(limit: Int = 200) -> [CaptureLedgerEntry]
    {
        let entries = self.loadEntries()
        return Array(entries.suffix(limit).reversed())
    }

    public func clear()
    {
        guard let fileURL = self.fileURL else { return }

        self.queue.sync {
            var coordinationError: NSError?
            self.coordinator.coordinate(writingItemAt: fileURL, options: .forDeleting, error: &coordinationError) { (url) in
                try? Data().write(to: url, options: .atomic)
            }
        }
    }
}
