//
//  ClippingTransform.swift
//  ClipKit
//
//  Created by Oliver Ames on 10/20/26.
//

import Foundation

/// A one-tap text transformation that can be applied to a clipping.
public enum ClippingTransform: CaseIterable
{
    case uppercase
    case lowercase
    case titleCase
    case camelCase
    case snakeCase
    case kebabCase
    case prettyJSON
    case minifiedJSON
    case urlEncode
    case urlDecode
    case base64Encode
    case base64Decode
    case stripMarkdown
    case trimWhitespace
    case sortLines
    case removeDuplicateLines

    /// A localized, human-readable name for menus and buttons.
    public var title: String
    {
        switch self
        {
        case .uppercase: return NSLocalizedString("UPPERCASE", comment: "")
        case .lowercase: return NSLocalizedString("lowercase", comment: "")
        case .titleCase: return NSLocalizedString("Title Case", comment: "")
        case .camelCase: return NSLocalizedString("camelCase", comment: "")
        case .snakeCase: return NSLocalizedString("snake_case", comment: "")
        case .kebabCase: return NSLocalizedString("kebab-case", comment: "")
        case .prettyJSON: return NSLocalizedString("Pretty JSON", comment: "")
        case .minifiedJSON: return NSLocalizedString("Minified JSON", comment: "")
        case .urlEncode: return NSLocalizedString("URL Encode", comment: "")
        case .urlDecode: return NSLocalizedString("URL Decode", comment: "")
        case .base64Encode: return NSLocalizedString("Base64 Encode", comment: "")
        case .base64Decode: return NSLocalizedString("Base64 Decode", comment: "")
        case .stripMarkdown: return NSLocalizedString("Strip Markdown", comment: "")
        case .trimWhitespace: return NSLocalizedString("Trim Whitespace", comment: "")
        case .sortLines: return NSLocalizedString("Sort Lines", comment: "")
        case .removeDuplicateLines: return NSLocalizedString("Remove Duplicate Lines", comment: "")
        }
    }

    /// Returns the transformed text, or nil if the transform can't apply to this text
    /// (invalid JSON, invalid Base64, or percent-encoding that can't be decoded).
    public func apply(to text: String) -> String?
    {
        switch self
        {
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        case .titleCase: return Self.titleCased(text)
        case .camelCase: return Self.camelCased(text)
        case .snakeCase: return Self.words(in: text).map { $0.lowercased() }.joined(separator: "_")
        case .kebabCase: return Self.words(in: text).map { $0.lowercased() }.joined(separator: "-")
        case .prettyJSON: return Self.reserializedJSON(text, options: [.prettyPrinted])
        case .minifiedJSON: return Self.reserializedJSON(text, options: [])
        case .urlEncode: return text.addingPercentEncoding(withAllowedCharacters: Self.urlUnreserved)
        case .urlDecode: return text.removingPercentEncoding
        case .base64Encode: return Data(text.utf8).base64EncodedString()
        case .base64Decode: return Self.base64Decoded(text)
        case .stripMarkdown: return Self.markdownStripped(text)
        case .trimWhitespace: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .sortLines: return Self.mapLines(of: text) { $0.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
        case .removeDuplicateLines:
            return Self.mapLines(of: text) { lines in
                var seen = Set<String>()
                return lines.filter { seen.insert($0).inserted }
            }
        }
    }
}

private extension ClippingTransform
{
    /// RFC 3986 unreserved characters. Everything else is percent-encoded, including "/" and "&".
    static let urlUnreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func titleCased(_ text: String) -> String
    {
        var result = ""
        var startsWord = true

        for character in text
        {
            if character.isWhitespace
            {
                result.append(character)
                startsWord = true
            }
            else
            {
                result += startsWord ? character.uppercased() : character.lowercased()
                startsWord = false
            }
        }

        return result
    }

    /// Splits on anything that isn't a letter or number, and on lowercase-to-uppercase transitions ("fooBar" is two words).
    static func words(in text: String) -> [String]
    {
        var words = [String]()
        var current = ""
        var previous: Character?

        for character in text
        {
            guard character.isLetter || character.isNumber else
            {
                if !current.isEmpty { words.append(current) }
                current = ""
                previous = nil
                continue
            }

            if let previous, previous.isLowercase, character.isUppercase
            {
                words.append(current)
                current = ""
            }

            current.append(character)
            previous = character
        }

        if !current.isEmpty { words.append(current) }
        return words
    }

    static func camelCased(_ text: String) -> String
    {
        let lowered = words(in: text).map { $0.lowercased() }
        guard let first = lowered.first else { return "" }
        return first + lowered.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    /// Object keys come out sorted, since JSONSerialization doesn't preserve their order.
    static func reserializedJSON(_ text: String, options: JSONSerialization.WritingOptions) -> String?
    {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let output = try? JSONSerialization.data(withJSONObject: object, options: options.union([.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]))
        else { return nil }

        return String(data: output, encoding: .utf8)
    }

    /// Ignores whitespace, so Base64 wrapped across several lines still decodes. Returns nil if the result isn't UTF-8 text.
    static func base64Decoded(_ text: String) -> String?
    {
        let compact = text.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: compact) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Strips common Markdown syntax with regular expressions: heading hashes, code fences, backticks,
    /// `*`/`_`/`~~` emphasis, and `[text](url)` links and images (keeping the text).
    /// It does not parse Markdown. Lists, blockquotes, tables, HTML, reference-style links, and emphasis spanning lines are left as written.
    static func markdownStripped(_ text: String) -> String
    {
        let rules: [(pattern: String, template: String)] = [
            ("(?m)^[ \\t]*(```|~~~)[^\\n]*\\n?", ""),
            ("!?\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),
            ("(?m)^[ \\t]{0,3}#{1,6}[ \\t]+", ""),
            ("(`+)(.+?)\\1", "$2"),
            ("(\\*{1,3})(?=\\S)(.+?)(?<=\\S)\\1", "$2"),
            ("(?<!\\w)(_{1,3})(?=\\S)(.+?)(?<=\\S)\\1(?!\\w)", "$2"),
            ("~~(?=\\S)(.+?)(?<=\\S)~~", "$1"),
        ]

        return rules.reduce(text) { result, rule in
            result.replacingOccurrences(of: rule.pattern, with: rule.template, options: .regularExpression)
        }
    }

    /// Applies `transform` to the lines of `text`, joining them with the text's first line ending
    /// and keeping a trailing line ending only if the text had one.
    static func mapLines(of text: String, _ transform: ([String]) -> [String]) -> String
    {
        let ending = text.first(where: \.isNewline) ?? "\n"
        var lines = text.split(separator: ending, omittingEmptySubsequences: false).map(String.init)

        let hasTrailingEnding = text.last == ending
        if hasTrailingEnding { lines.removeLast() }

        return transform(lines).joined(separator: String(ending)) + (hasTrailingEnding ? String(ending) : "")
    }
}
