//
//  ClippingKind.swift
//  ClipboardKit
//
//  How a clipping presents itself: its kind, name, symbol, and accent color. The app,
//  the keyboard, and the map all draw clippings the same way from this one description.
//

import UIKit
import SwiftUI

public enum ClippingKind: Equatable
{
    case text
    case richText
    case image
    case link
    case code(CodeLanguage)

    public init(_ item: PasteboardItem)
    {
        if item.linkURL != nil
        {
            self = .link
            return
        }

        switch item.preferredRepresentation?.type
        {
        case .image?: self = .image
        case .url?: self = .link
        case .attributedText?, .text?:
            // Detection only needs the start of a clipping, and long clippings shouldn't stall scrolling.
            if let text = item.contentText, let language = CodeDetector.detect(String(text.prefix(4_000)))
            {
                self = .code(language)
            }
            else
            {
                self = (item.preferredRepresentation?.type == .attributedText) ? .richText : .text
            }
        case nil: self = .text
        }
    }

    /// A short name for the kind, such as "Text", "Link", or a code language like "Swift".
    public var title: String {
        switch self
        {
        case .text: return NSLocalizedString("Text", comment: "")
        case .richText: return NSLocalizedString("Rich Text", comment: "")
        case .image: return NSLocalizedString("Image", comment: "")
        case .link: return NSLocalizedString("Link", comment: "")
        case .code(let language): return language.displayName
        }
    }

    public var symbolName: String {
        switch self
        {
        case .text: return "text.alignleft"
        case .richText: return "textformat"
        case .image: return "photo"
        case .link: return "link"
        case .code: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// The accent that tells kinds apart at a glance. System colors adapt to dark mode and Increase Contrast.
    public var tintColor: UIColor {
        switch self
        {
        case .text: return .systemGray
        case .richText: return .systemOrange
        case .image: return .systemPink
        case .link: return .systemBlue
        case .code: return .systemIndigo
        }
    }

    public var color: Color { Color(uiColor: self.tintColor) }

    public var isCode: Bool {
        if case .code = self { return true }
        return false
    }
}

public extension PasteboardItem
{
    /// A spoken summary for VoiceOver: kind, content, age, and state, in that order.
    func accessibilityDescription(kind: ClippingKind, title: String?) -> String
    {
        var parts = [kind.title]

        if let title, !title.isEmpty
        {
            parts.append(String(title.prefix(200)))
        }

        let age = RelativeDateTimeFormatter().localizedString(for: self.date, relativeTo: Date())
        parts.append(age)

        if self.isPinned { parts.append(NSLocalizedString("Pinned", comment: "")) }
        if self.isFavorite { parts.append(NSLocalizedString("Favorite", comment: "")) }

        return parts.joined(separator: ", ")
    }
}
