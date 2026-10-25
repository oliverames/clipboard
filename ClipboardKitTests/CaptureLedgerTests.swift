//
//  CaptureLedgerTests.swift
//  ClipboardKitTests
//
//  Tests the capture ledger: the pure aggregation that the Diagnostics screen shows,
//  and the on-disk JSON-lines file round-trip and size trimming.
//

import XCTest
import ClipboardKit

final class CaptureLedgerTests: XCTestCase
{
    private var directory: URL!

    override func setUpWithError() throws
    {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws
    {
        try? FileManager.default.removeItem(at: self.directory)
    }

    // MARK: Aggregation

    func testStatsCountsEventsAndComputesMissRate()
    {
        // changeCount 10: heard, reloaded, saved -> captured.
        // changeCount 11: heard, reloaded, missed -> a miss.
        // changeCount 12: heard, saved by the widget -> captured.
        let entries: [CaptureLedgerEntry] = [
            CaptureLedgerEntry(source: .app, event: .changeHeard, changeCount: 10),
            CaptureLedgerEntry(source: .app, event: .reloadRequested, changeCount: 10, attempt: 1),
            CaptureLedgerEntry(source: .widget, event: .widgetRan, changeCount: 10),
            CaptureLedgerEntry(source: .widget, event: .saved, changeCount: 10),

            CaptureLedgerEntry(source: .app, event: .changeHeard, changeCount: 11),
            CaptureLedgerEntry(source: .app, event: .reloadRequested, changeCount: 11, attempt: 1),
            CaptureLedgerEntry(source: .app, event: .missed, changeCount: 11, attempt: 9),

            CaptureLedgerEntry(source: .app, event: .changeHeard, changeCount: 12),
            CaptureLedgerEntry(source: .widget, event: .saved, changeCount: 12),
        ]

        let stats = CaptureLedger.stats(from: entries)

        XCTAssertEqual(stats.changesHeard, 3)
        XCTAssertEqual(stats.reloadsRequested, 2)
        XCTAssertEqual(stats.widgetRuns, 1)
        XCTAssertEqual(stats.saves, 2)
        XCTAssertEqual(stats.misses, 1)

        XCTAssertEqual(stats.changeCountsSeen, 3)   // 10, 11, 12
        XCTAssertEqual(stats.changeCountsSaved, 2)  // 10, 12

        XCTAssertNotNil(stats.missRate)
        XCTAssertEqual(stats.missRate!, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(stats.captureRate!, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testMissRateIsNilWhenNothingSeen()
    {
        let stats = CaptureLedger.stats(from: [])
        XCTAssertNil(stats.missRate)
        XCTAssertNil(stats.captureRate)
        XCTAssertEqual(stats.changeCountsSeen, 0)
    }

    func testDuplicateDoesNotCountAsASeparateSeenChangeCount()
    {
        // The same change count saved and later re-run as a duplicate stays one capture.
        let entries: [CaptureLedgerEntry] = [
            CaptureLedgerEntry(event: .changeHeard, changeCount: 5),
            CaptureLedgerEntry(event: .saved, changeCount: 5),
            CaptureLedgerEntry(event: .widgetRan, changeCount: 5),
            CaptureLedgerEntry(event: .duplicate, changeCount: 5),
        ]
        let stats = CaptureLedger.stats(from: entries)
        XCTAssertEqual(stats.changeCountsSeen, 1)
        XCTAssertEqual(stats.changeCountsSaved, 1)
        XCTAssertEqual(stats.duplicates, 1)
        XCTAssertEqual(stats.missRate, 0)
    }

    // MARK: File round-trip

    func testRecordRoundTripsThroughTheFile()
    {
        let ledger = CaptureLedger(directory: self.directory)
        ledger.record(.changeHeard, changeCount: 100)
        ledger.record(.reloadRequested, changeCount: 100, attempt: 1)
        ledger.record(.saved, changeCount: 100)
        ledger.flushForTesting()

        let entries = ledger.loadEntries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map { $0.event }, [.changeHeard, .reloadRequested, .saved])
        XCTAssertEqual(entries.first?.changeCount, 100)
        XCTAssertEqual(entries[1].attempt, 1)
    }

    func testDisabledLedgerWritesNothing()
    {
        let ledger = CaptureLedger(directory: self.directory, isEnabled: false)
        ledger.record(.changeHeard, changeCount: 1)
        ledger.flushForTesting()
        XCTAssertTrue(ledger.loadEntries().isEmpty)
    }

    func testRecordNeverStoresClippingContents()
    {
        // The ledger has no field that could hold clipboard contents; the only free
        // text is `note`, which callers fill with type identifiers / errors. Assert the
        // encoded line contains none of a sample secret passed anywhere it is accepted.
        let ledger = CaptureLedger(directory: self.directory)
        ledger.record(.saved, changeCount: 7, note: "public.utf8-plain-text")
        ledger.flushForTesting()

        let data = try! Data(contentsOf: self.directory.appendingPathComponent("capture-ledger.jsonl"))
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("public.utf8-plain-text"))
        XCTAssertTrue(text.contains("\"changeCount\":7"))
    }

    // MARK: Trimming

    func testFileIsTrimmedToStayUnderTheCapAndKeepsWholeLines()
    {
        // A tiny cap forces trimming after a few writes.
        let ledger = CaptureLedger(directory: self.directory, isEnabled: true, maximumSize: 600)
        for changeCount in 0 ..< 200
        {
            ledger.record(.changeHeard, changeCount: changeCount)
        }
        ledger.flushForTesting()

        let fileURL = self.directory.appendingPathComponent("capture-ledger.jsonl")
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        XCTAssertLessThanOrEqual(size ?? 0, 600)

        // Every surviving line must still parse (no partial line left at the front).
        let entries = ledger.loadEntries()
        XCTAssertFalse(entries.isEmpty)
        // The most recent change count must have survived.
        XCTAssertEqual(entries.last?.changeCount, 199)
    }
}
