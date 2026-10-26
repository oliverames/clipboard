//
//  DiagnosticsScrubber.swift
//  ClipboardKit
//
//  Removes anything that could carry clipboard contents, or identify a person, from text
//  before it leaves the device in a crash or error report.
//

import Foundation

/// The second line of defence for crash and error reports. Reports are built from fixed
/// messages and counts, so nothing the person copied is ever put into one on purpose. This runs
/// on every breadcrumb and event the SDK is about to send, including text the system or the SDK
/// added, such as an exception's reason.
///
/// Clipboard's private data is what people copy: text, links, file names, images, and the place
/// each clipping was copied. A general pattern can't recognise arbitrary copied text, so free
/// text that didn't come from the app's own fixed messages is not trusted at all:
/// `exceptionValue(_:)` keeps an exception's reason only when it matches one of the system's
/// known technical formats and drops it otherwise. Everything else is scrubbed for URLs, paths,
/// emails, coordinates, hosts and long tokens, and data keys that name contents are dropped.
/// Order matters: whole URLs go first, so their hosts and query strings never reach the
/// narrower rules, and IP addresses go before coordinates.
public enum DiagnosticsScrubber
{
    /// Longer text is cut; reports never need paragraphs.
    public static let maximumLength = 240

    /// What a dropped exception reason becomes.
    public static let redacted = "<redacted>"

    private static let rules: [(NSRegularExpression, String)] = {
        let patterns: [(String, String)] = [
            // Any URL, with its host, path, query string and fragment.
            (#"[A-Za-z][A-Za-z0-9+.-]*://[^\s"'<>]+"#, "<url>"),
            // Bearer credentials first, so a header line keeps its token covered.
            (#"(?i)\bbearer\s+\S+"#, "Bearer <redacted>"),
            // Header and cookie lines, and key=value or key: value secrets.
            (#"(?i)\b(authorization|cookie|set-cookie|x-[a-z0-9-]+|api[_-]?key|token|access[_-]?token|auth|password|secret|session(?:id)?)\b\s*[:=]\s*\S+"#, "$1=<redacted>"),
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
            // File system paths (app container, Caches, the App Group), which can name a file.
            (#"(?:/private)?/(?:var|Users|private|tmp|Library|System/Volumes)/[^\s"']*"#, "<path>"),
            (#"(?:~|file:)/[^\s"']*"#, "<path>"),
            // IPv4 and long-form IPv6 addresses.
            (#"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b"#, "<ip>"),
            (#"\b(?:[0-9A-Fa-f]{1,4}:){3,7}[0-9A-Fa-f]{1,4}\b"#, "<ip>"),
            // Coordinates: any decimal with three or more fractional digits, which is street-level
            // or better for latitude and longitude. Versions such as 9.31.0 have fewer.
            (#"-?\b\d{1,3}\.\d{3,}\b"#, "<coord>"),
            // Bare host names: dotted, all lowercase, ending in a letters-only label. Type names and
            // error domains carry capitals (`ClipboardKit.PasteboardError`) and stay.
            (#"\b[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*\.[a-z]{2,12}\b(?::\d+)?"#, "<host>"),
            // Quoted text, which in system messages is usually a value: a string, a key, a name.
            (#""[^"]*"|'[^']*'|“[^”]*”"#, "<quoted>"),
            // Long opaque tokens: hex, base64 and JWT-like runs.
            (#"\b[A-Za-z0-9_-]{32,}\b"#, "<token>"),
            (#"\b[A-Fa-f0-9]{24,}\b"#, "<token>"),
        ]
        return patterns.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
        }
    }()

    public static func scrub(_ text: String) -> String
    {
        var result = text
        for (expression, template) in rules
        {
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        if result.count > maximumLength { result = String(result.prefix(maximumLength)) + "…" }
        return result
    }

    /// An exception's reason, kept only when it is one of the technical formats below and
    /// scrubbed even then. Any other reason, such as an `NSInvalidArgumentException` or a Core
    /// Data validation message, can quote the object it failed on, which may be a clipping, so it
    /// is replaced with `redacted`. The exception's type and stack trace still go.
    public static func exceptionValue(_ value: String) -> String
    {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowedExceptionPrefixes.contains(where: { trimmed.hasPrefix($0) }) else { return redacted }
        return scrub(trimmed)
    }

    /// Reasons written by the Sentry SDK, MetricKit and the crash handler, which describe the
    /// failure rather than the data it involved.
    private static let allowedExceptionPrefixes = [
        "App hanging", "App Hanging", "Fatal App Hang", "The OS watchdog terminated",
        "MXHangDiagnostic", "MXCPUException", "MXDiskWriteException", "MXCrashDiagnostic",
        "KERN_", "EXC_", "Attempted to dereference", "Stack overflow", "Signal ",
        "Fatal error: Unexpectedly found nil", "Fatal error: Index out of range",
        "Fatal error: Division by zero", "Fatal error: Range requires lowerBound",
        "Fatal error: Array index is out of range",
        "Not enough memory",
    ]

    /// An event's fingerprint, which is sent with it: each part scrubbed like any other text.
    public static func fingerprint(_ parts: [String]) -> [String]
    {
        parts.map { scrub($0) }
    }

    /// Scrubs every string inside a breadcrumb's or event's data, keeping numbers and booleans.
    /// Keys that name a sensitive value are dropped outright, whatever their value.
    public static func scrub(_ data: [String: Any]) -> [String: Any]
    {
        var clean: [String: Any] = [:]
        for (key, value) in data where !isSensitiveKey(key)
        {
            switch value
            {
            case let text as String: clean[key] = scrub(text)
            case let number as NSNumber: clean[key] = number
            case let nested as [String: Any]: clean[key] = scrub(nested)
            case let list as [Any]:
                clean[key] = list.compactMap { item -> Any? in
                    if let text = item as? String { return scrub(text) }
                    if let number = item as? NSNumber { return number }
                    return nil
                }
            default: break
            }
        }
        return clean
    }

    /// Which event contexts may leave the device, and which fields of each. The SDK can put an
    /// error's user info and other free-form dictionaries into an event's contexts, so everything
    /// not listed is dropped, `user info` included.
    private static let allowedContextFields: [String: Set<String>] = [
        "os": ["os", "name", "version", "build", "kernel_version", "rooted", "type"],
        "device": ["family", "model", "model_id", "arch", "simulator", "memory_size", "free_memory",
                   "usable_memory", "storage_size", "free_storage", "processor_count", "low_power_mode",
                   "thermal_state", "type"],
        "app": ["app_identifier", "app_name", "app_version", "app_build", "build_type", "app_id",
                "app_start_time", "app_memory", "in_foreground", "is_active", "type"],
        // The SDK's own trace identifiers (random per launch) and runtime description.
        "trace": ["trace_id", "span_id", "status", "type"],
        "runtime": ["name", "version", "raw_description", "type"],
    ]

    /// Keeps only the allowed contexts and fields, then scrubs whatever strings remain. The device's
    /// name and locale, the per-device app hash, culture, user and user info never pass.
    public static func context(_ context: [String: [String: Any]]) -> [String: [String: Any]]
    {
        var clean: [String: [String: Any]] = [:]
        for (name, fields) in context {
            guard let allowed = allowedContextFields[name] else { continue }
            var kept: [String: Any] = [:]
            for (key, value) in fields where allowed.contains(key) {
                switch value {
                case let text as String: kept[key] = scrub(text)
                case let number as NSNumber: kept[key] = number
                default: break
                }
            }
            if !kept.isEmpty { clean[name] = kept }
        }
        return clean
    }

    /// Splits camelCase, snake_case and dotted keys into words and drops the key when any word
    /// names something sensitive: `pasteboardText`, `item_title` and `fileName` all go, so
    /// reporting code names counts plainly (`count`, `status`).
    public static func isSensitiveKey(_ key: String) -> Bool
    {
        var words: [String] = []
        var current = ""
        for character in key
        {
            if character.isUppercase, !current.isEmpty { words.append(current); current = "" }
            if character.isLetter || character.isNumber { current.append(character) }
            else if !current.isEmpty { words.append(current); current = "" }
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }.contains(where: sensitiveWords.contains)
    }

    private static let sensitiveWords: Set<String> = [
        // What was copied.
        "pasteboard", "clipboard", "clipping", "clippings", "content", "contents", "text", "string",
        "value", "values", "item", "items", "representation", "representations", "preview", "snippet",
        "title", "name", "body", "summary", "description", "detail", "details", "message", "note",
        "list", "query", "search", "term", "image", "html", "rtf", "data", "uti",
        // Where it was copied.
        "lat", "lon", "lng", "latitude", "longitude", "coord", "coords", "coordinate", "coordinates",
        "location", "town", "city", "place", "places", "address", "region",
        // Links, files and identity.
        "url", "uri", "link", "host", "hostname", "domain", "file", "filename", "path",
        "header", "headers", "cookie", "cookies", "token", "key", "password", "secret",
        "email", "ip", "user", "account", "device",
    ]
}
