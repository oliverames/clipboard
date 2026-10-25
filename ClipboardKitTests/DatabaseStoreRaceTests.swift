//
//  DatabaseStoreRaceTests.swift
//  ClipboardKitTests
//
//  The store loads asynchronously. A copy that arrives before the store is ready must
//  not be dropped: prepare() has to queue every waiting caller and satisfy them all
//  once the store finishes loading. These tests exercise that coalescing against an
//  in-memory store so nothing touches disk or an App Group.
//

import XCTest
import CoreData
import ClipboardKit

final class DatabaseStoreRaceTests: XCTestCase
{
    func testPrepareSatisfiesEveryCallerThatRacedTheLoad()
    {
        let manager = DatabaseManager.shared
        manager.useInMemoryStoreForTesting()

        // Fire several prepare() calls back to back, before the first load can finish.
        let callers = 5
        let allReady = expectation(description: "every racing caller gets success")
        allReady.expectedFulfillmentCount = callers

        var successes = 0
        let lock = NSLock()

        for _ in 0 ..< callers
        {
            manager.prepare { result in
                if case .success = result
                {
                    lock.lock(); successes += 1; lock.unlock()
                    allReady.fulfill()
                }
            }
        }

        wait(for: [allReady], timeout: 10)
        XCTAssertEqual(successes, callers)
        XCTAssertTrue(manager.isStarted)
    }

    func testPrepareAfterStartReturnsImmediately()
    {
        let manager = DatabaseManager.shared
        manager.useInMemoryStoreForTesting()

        let first = expectation(description: "first prepare")
        manager.prepare { _ in first.fulfill() }
        wait(for: [first], timeout: 10)

        // Once started, a late caller (the common case: a copy arrives after launch)
        // is satisfied without reloading.
        let late = expectation(description: "late prepare")
        manager.prepare { result in
            if case .success = result { late.fulfill() }
        }
        wait(for: [late], timeout: 5)
        XCTAssertTrue(manager.isStarted)
    }
}
