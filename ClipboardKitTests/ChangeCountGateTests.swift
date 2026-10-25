//
//  ChangeCountGateTests.swift
//  ClipboardKitTests
//
//  The gate that makes the widget's read idempotent: a change count is handled once.
//

import XCTest
import ClipboardKit

final class ChangeCountGateTests: XCTestCase
{
    func testNewChangeCountIsProcessed()
    {
        XCTAssertTrue(ChangeCountGate.shouldProcess(42, lastHandled: 41))
    }

    func testAlreadyHandledChangeCountIsSkipped()
    {
        XCTAssertFalse(ChangeCountGate.shouldProcess(42, lastHandled: 42))
    }

    func testZeroIsAlwaysProcessed()
    {
        // The pasteboard reports change count 0 before it is ever read; never dedup it.
        XCTAssertTrue(ChangeCountGate.shouldProcess(0, lastHandled: 0))
        XCTAssertTrue(ChangeCountGate.shouldProcess(0, lastHandled: 5))
    }

    func testMonotonicSequenceProcessesEachOnce()
    {
        var lastHandled = 0
        var processedCount = 0
        // The same change count arriving twice (widget run twice) is handled once.
        for changeCount in [7, 7, 8, 8, 8, 9]
        {
            if ChangeCountGate.shouldProcess(changeCount, lastHandled: lastHandled)
            {
                processedCount += 1
                lastHandled = changeCount
            }
        }
        XCTAssertEqual(processedCount, 3) // 7, 8, 9 — once each
    }
}
