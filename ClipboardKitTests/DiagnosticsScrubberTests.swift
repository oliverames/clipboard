//
//  DiagnosticsScrubberTests.swift
//  ClipboardKitTests
//
//  What may leave the device in a crash or error report. Every string a breadcrumb or event
//  carries goes through DiagnosticsScrubber on its way out, and exception reasons are dropped
//  unless they match a known technical format.
//

import XCTest
import ClipboardKit

final class DiagnosticsScrubberTests: XCTestCase
{
    func testCopiedTextInExceptionReasonsIsDropped()
    {
        for reason in [
            "Can't save clipping \"Meet at the pier, code 4417\"",
            "*** -[__NSCFString substringToIndex:]: Index 40 out of bounds; string length 12",
            "The operation couldn't be completed. Validation error for PasteboardItem with text Taxes 2026",
            "Meet at the pier, code 4417",
        ]
        {
            XCTAssertEqual(DiagnosticsScrubber.exceptionValue(reason), DiagnosticsScrubber.redacted, reason)
        }
    }

    func testTechnicalExceptionReasonsAreKept()
    {
        XCTAssertEqual(DiagnosticsScrubber.exceptionValue("App hanging for at least 2000 ms."), "App hanging for at least 2000 ms.")
        XCTAssertEqual(DiagnosticsScrubber.exceptionValue("KERN_INVALID_ADDRESS at 0x10"), "KERN_INVALID_ADDRESS at 0x10")
        XCTAssertEqual(DiagnosticsScrubber.exceptionValue("Fatal error: Unexpectedly found nil while unwrapping an Optional value"),
                       "Fatal error: Unexpectedly found nil while unwrapping an Optional value")
    }

    func testURLsPathsEmailsCoordinatesAndQuotesGo()
    {
        XCTAssertEqual(DiagnosticsScrubber.scrub("open https://clip.example/a?id=7"), "open <url>")
        XCTAssertEqual(DiagnosticsScrubber.scrub("asked itunes.apple.com"), "asked <host>")
        XCTAssertEqual(DiagnosticsScrubber.scrub("relay 10.0.0.2:8443 down"), "relay <ip> down")
        XCTAssertEqual(DiagnosticsScrubber.scrub("from oliver@example.com"), "from <email>")
        XCTAssertEqual(DiagnosticsScrubber.scrub("open /private/var/mobile/Containers/Shared/AppGroup/x/Taxes.pdf"), "open <path>")
        XCTAssertEqual(DiagnosticsScrubber.scrub("near 44.4759, -73.2121"), "near <coord>, <coord>")
        XCTAssertEqual(DiagnosticsScrubber.scrub("copied \"Meet at the pier\" now"), "copied <quoted> now")
        XCTAssertEqual(DiagnosticsScrubber.scrub("token=deadbeef"), "token=<redacted>")
    }

    func testFixedMessagesAndDomainsPassUnchanged()
    {
        for text in ["Launched", "Database failed to load", "NSCocoaErrorDomain", "ClipboardKit.PasteboardError",
                     "Clipboard diagnostics check", "sentry-cocoa 9.31.0", "status 503"]
        {
            XCTAssertEqual(DiagnosticsScrubber.scrub(text), text)
        }
    }

    func testLongTextIsCut()
    {
        let text = DiagnosticsScrubber.scrub(String(repeating: "word ", count: 200))
        XCTAssertEqual(text.count, DiagnosticsScrubber.maximumLength + 1)
    }

    func testDataKeysNamingContentsOrPlacesAreDropped()
    {
        let clean = DiagnosticsScrubber.scrub([
            "pasteboardText": "Meet at the pier", "itemTitle": "Taxes 2026", "fileName": "Taxes 2026.pdf",
            "url": "https://a.example", "town": "Burlington", "latitude": 44.4759, "preview_html": "<b>x</b>",
            "count": 3, "status": 503, "errorCode": 256, "errorType": "CocoaError",
            "reason": "near 44.4759,-73.2121",
        ] as [String: Any])
        XCTAssertEqual(Set(clean.keys), ["count", "status", "errorCode", "errorType", "reason"])
        XCTAssertEqual(clean["count"] as? Int, 3)
        XCTAssertEqual(clean["reason"] as? String, "near <coord>,<coord>")
    }
}
