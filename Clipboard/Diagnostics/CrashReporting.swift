//
//  CrashReporting.swift
//  Clipboard
//
//  Crash, hang and error reporting through Sentry.
//

import Foundation
import Sentry

import ClipboardKit

/// What part of the app a breadcrumb or report comes from. These are Sentry categories.
enum DiagnosticsArea: String
{
    case app, database, test
}

/// Crash, hang and error reporting through Sentry.
///
/// Optional in every sense: a build without `CLIPBOARD_SENTRY_DSN` (Config/Diagnostics.xcconfig)
/// never starts the SDK, and Settings > Diagnostics > Share Crash Reports turns it off. It runs
/// in the app only, not in the widget or keyboard extensions, and it doesn't touch how the
/// clipboard is monitored. It records native crashes, app hangs over two seconds, watchdog
/// terminations and MetricKit hang and CPU diagnostics, plus breadcrumbs the app adds itself from
/// fixed messages and counts.
///
/// Reports never carry clipboard contents: no copied text, item titles, links, file names, images
/// or the place a clipping was copied. Exception reasons are dropped unless they match a known
/// technical format, because a system exception can quote the object it failed on. There is no
/// IP address, device name, locale, time zone, screenshot, view hierarchy or session replay
/// either, and `DiagnosticsScrubber` cleans every remaining string on its way out.
///
/// Debug builds report only when launched with `-ClipboardCrashReports YES` or a test argument,
/// so ordinary development runs stay out of the project. `-ClipboardSentryTest message` (or
/// `error`, `crash`, `hang`) sends a fixed check, for confirming delivery and scrubbing.
enum CrashReporting
{
    static let preferenceKey = "diagnostics.crash_reports"
    private static let dsnKey = "ClipboardSentryDSN"

    /// The validated DSN this build carries, or nil when reporting isn't built in.
    static let dsn: String? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: dsnKey) as? String,
              !value.isEmpty, !value.contains("$("),
              let url = URLComponents(string: value), url.scheme == "https",
              url.host?.hasSuffix(".sentry.io") == true, url.user?.isEmpty == false,
              url.password == nil, url.query == nil else { return nil }
        return value
    }()

    static var isConfigured: Bool { dsn != nil }

    /// On unless the person turned it off. Read on every launch.
    static var isPreferenceOn: Bool {
        UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true
    }

    static var isRunning: Bool { SentrySDK.isEnabled }

    /// Starts reporting when the build has a DSN and the person hasn't turned it off. Call once,
    /// first thing at launch, on the main thread.
    static func start()
    {
        guard let dsn, isPreferenceOn, !SentrySDK.isEnabled else { return }
        #if DEBUG
        let test = UserDefaults.standard.string(forKey: "ClipboardSentryTest")
        guard UserDefaults.standard.bool(forKey: "ClipboardCrashReports") || test != nil else { return }
        #endif
        SentrySDK.start(options: options(dsn: dsn))
        breadcrumb(.app, "Launched")
        #if DEBUG
        if let test { runTest(test) }
        #endif
    }

    /// Settings' Share Crash Reports. Takes effect at once: off closes the SDK and its crash
    /// handler, on starts it again.
    static func setEnabled(_ enabled: Bool)
    {
        UserDefaults.standard.set(enabled, forKey: preferenceKey)
        if enabled { start() } else if SentrySDK.isEnabled { SentrySDK.close() }
    }

    // MARK: Breadcrumbs and reports

    /// A step leading up to a possible crash. Message is a fixed phrase; data holds counts and
    /// status codes, never anything that was copied.
    static func breadcrumb(_ area: DiagnosticsArea, _ message: String, data: [String: Any] = [:],
                           level: SentryLevel = .info)
    {
        guard SentrySDK.isEnabled else { return }
        let crumb = Breadcrumb(level: level, category: area.rawValue)
        crumb.message = message
        for (key, value) in data { crumb.setData(value: value, key: key) }
        SentrySDK.addBreadcrumb(crumb)
    }

    /// A non-fatal failure worth fixing. Only the error's type, domain and code go with it; its
    /// description can hold a file name or part of a clipping.
    static func report(_ area: DiagnosticsArea, _ message: String, error: Error? = nil,
                       data: [String: Any] = [:], level: SentryLevel = .error)
    {
        guard SentrySDK.isEnabled else { return }
        if let error, isCancellation(error) { return }
        let event = Event(level: level)
        event.message = SentryMessage(formatted: message)
        var tags = ["area": area.rawValue]
        var extra = data
        if let error
        {
            let nsError = error as NSError
            tags["error.domain"] = nsError.domain
            extra["errorType"] = String(describing: type(of: error))
            extra["errorCode"] = nsError.code
        }
        event.tags = tags
        if !extra.isEmpty { event.extra = extra }
        // Group by area and message rather than by stack.
        event.fingerprint = [area.rawValue, message, tags["error.domain"] ?? "-"]
        SentrySDK.capture(event: event)
    }

    static func isCancellation(_ error: Error) -> Bool
    {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    // MARK: Options

    private static func options(dsn: String) -> Options
    {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        let options = Options()
        options.dsn = dsn
        options.releaseName = "com.oliverames.clipboard@\(version)+\(build)"
        options.dist = build
        #if DEBUG
        options.environment = "debug"
        #else
        options.environment = "release"
        #endif
        options.debug = false
        options.sendDefaultPii = false
        options.sendClientReports = false
        options.enableCrashHandler = true
        options.enableWatchdogTerminationTracking = true
        options.enableAppHangTracking = true
        options.appHangTimeoutInterval = 2
        options.attachStacktrace = true
        options.maxBreadcrumbs = 100
        // No sessions (they carry an installation identifier), performance tracing, network
        // capture, automatic UI breadcrumbs, screenshots, view hierarchy or replay. Automatic
        // breadcrumbs are off because UI ones can carry a button or cell's text.
        options.enableAutoSessionTracking = false
        options.tracesSampleRate = 0
        options.enableAutoPerformanceTracing = false
        options.enableUIViewControllerTracing = false
        options.enableUserInteractionTracing = false
        options.enablePreWarmedAppStartTracing = false
        options.enableNetworkTracking = false
        options.enableNetworkBreadcrumbs = false
        options.enableCaptureFailedRequests = false
        options.enableFileIOTracing = false
        options.enableDataSwizzling = false
        options.enableFileManagerSwizzling = false
        options.enableCoreDataTracing = false
        options.enableAutoBreadcrumbTracking = false
        options.enableSwizzling = false
        options.attachScreenshot = false
        options.attachViewHierarchy = false
        options.sessionReplay.sessionSampleRate = 0
        options.sessionReplay.onErrorSampleRate = 0
        options.maxAttachmentSize = 0
        options.tracePropagationTargets = []
        options.failedRequestTargets = []
        options.enableMetricKit = true
        options.enableMetricKitRawPayload = false
        options.beforeBreadcrumb = { crumb in
            scrub(crumb)
            return crumb
        }
        options.beforeSend = { event in
            sanitize(event)
            return event
        }
        return options
    }

    /// Cleans a breadcrumb's message and data in place: dropped keys are removed, the rest replaced.
    static func scrub(_ crumb: Breadcrumb)
    {
        if let message = crumb.message { crumb.message = DiagnosticsScrubber.scrub(message) }
        guard let data = crumb.data else { return }
        let clean = DiagnosticsScrubber.scrub(data)
        for key in data.keys { crumb.setData(value: clean[key], key: key) }
    }

    /// Strips identity and cleans every free-text field of an event about to be sent, including
    /// crash reports written by an earlier run.
    static func sanitize(_ event: Event)
    {
        event.user = nil
        event.request = nil
        event.serverName = nil
        if let message = event.message
        {
            event.message = SentryMessage(formatted: DiagnosticsScrubber.scrub(message.formatted))
        }
        for exception in event.exceptions ?? []
        {
            if let value = exception.value { exception.value = DiagnosticsScrubber.exceptionValue(value) }
            if let mechanism = exception.mechanism
            {
                if let desc = mechanism.desc { mechanism.desc = DiagnosticsScrubber.exceptionValue(desc) }
                if let data = mechanism.data { mechanism.data = DiagnosticsScrubber.scrub(data) }
            }
        }
        if var tags = event.tags
        {
            tags["app.device"] = nil
            event.tags = tags.mapValues(DiagnosticsScrubber.scrub)
        }
        if let extra = event.extra { event.extra = DiagnosticsScrubber.scrub(extra) }
        for crumb in event.breadcrumbs ?? [] { scrub(crumb) }
        // Only the listed contexts and fields go: the SDK can put an error's user info and other
        // free-form dictionaries here, and the device's name and locale, culture and the
        // per-device app hash identify the person.
        if let context = event.context { event.context = DiagnosticsScrubber.context(context) }
    }

    // MARK: Debug checks

    #if DEBUG
    /// Sends a fixed check. The breadcrumb and the error carry synthetic private text, so the
    /// received event shows whether scrubbing worked: none of it should arrive.
    private static func runTest(_ kind: String)
    {
        breadcrumb(.test, "Scrub check copied \"Meet at the pier, code 4417\" from https://clip.example/a?id=7 at 44.4759, -73.2121 via 10.0.0.2 into /private/var/mobile/Containers/Shared/AppGroup/x/Taxes 2026.pdf",
                   data: ["pasteboardText": "Meet at the pier, code 4417", "itemTitle": "Taxes 2026",
                          "fileName": "Taxes 2026.pdf", "town": "Burlington", "latitude": 44.4759,
                          "count": 3, "status": 200])
        switch kind
        {
        case "crash":
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                SentrySDK.crash()
            }
        case "hang":
            // Blocks the main thread for five seconds, past the two-second hang threshold.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let end = Date().addingTimeInterval(5)
                while Date() < end { usleep(10_000) }
            }
        case "exception":
            // Captured, not thrown: an exception reason quoting a clipping must arrive redacted.
            let exception = NSException(name: .invalidArgumentException,
                                        reason: "Can't save clipping \"Meet at the pier, code 4417\"", userInfo: nil)
            SentrySDK.capture(exception: exception)
        case "error":
            report(.test, "Clipboard diagnostics check (error)",
                   error: CocoaError(.fileReadCorruptFile), data: ["count": 3])
        default:
            report(.test, "Clipboard diagnostics check", data: ["count": 3], level: .info)
        }
        if kind == "message" || kind == "error" || kind == "exception" { SentrySDK.flush(timeout: 5) }
    }
    #endif
}
