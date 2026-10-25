//
//  PasteboardItem+CopyAs.swift
//  Clipboard
//

import UIKit

import ClipboardKit

extension ClippingTransform
{
    /// Transforms are grouped in menus by what they do.
    enum Group: CaseIterable
    {
        case letterCase
        case format
        case encoding
        case lines

        var title: String {
            switch self
            {
            case .letterCase: return NSLocalizedString("Case", comment: "")
            case .format: return NSLocalizedString("Format", comment: "")
            case .encoding: return NSLocalizedString("Encode and Decode", comment: "")
            case .lines: return NSLocalizedString("Clean Up", comment: "")
            }
        }
    }

    var group: Group {
        switch self
        {
        case .uppercase, .lowercase, .titleCase, .camelCase, .snakeCase, .kebabCase: return .letterCase
        case .prettyJSON, .minifiedJSON, .stripMarkdown: return .format
        case .urlEncode, .urlDecode, .base64Encode, .base64Decode: return .encoding
        case .trimWhitespace, .sortLines, .removeDuplicateLines: return .lines
        }
    }

    var symbolName: String {
        switch self
        {
        case .uppercase: return "textformat.size.larger"
        case .lowercase: return "textformat.size.smaller"
        case .titleCase: return "textformat"
        case .camelCase, .snakeCase, .kebabCase: return "character.cursor.ibeam"
        case .prettyJSON: return "curlybraces"
        case .minifiedJSON: return "arrow.down.right.and.arrow.up.left"
        case .stripMarkdown: return "number"
        case .urlEncode, .urlDecode: return "link"
        case .base64Encode, .base64Decode: return "lock.doc"
        case .trimWhitespace: return "scissors"
        case .sortLines: return "arrow.up.arrow.down"
        case .removeDuplicateLines: return "line.3.horizontal.decrease"
        }
    }
}

extension PasteboardItem
{
    /// A "Copy As" menu that copies the clipping's text after a transformation. Each action previews its result,
    /// and transformations that can't apply to the text stay visible but disabled.
    func makeCopyAsMenu(onCopy: (() -> Void)? = nil) -> UIMenu?
    {
        guard let text = self.contentText else { return nil }

        // Long clippings would make every subtitle the same truncated line, and transforming them all is wasted work.
        let sample = String(text.prefix(2_000))

        let groups: [UIMenuElement] = ClippingTransform.Group.allCases.map { group in
            let actions: [UIMenuElement] = ClippingTransform.allCases.filter { $0.group == group }.map { transform in
                let preview = transform.apply(to: sample)

                let subtitle = preview.map { result -> String in
                    let line = result.split(whereSeparator: \.isNewline).first.map(String.init) ?? result
                    return String(line.prefix(40))
                }

                return UIAction(title: transform.title, subtitle: subtitle, image: UIImage(systemName: transform.symbolName), attributes: preview == nil ? .disabled : []) { _ in
                    guard let result = transform.apply(to: text) else { return }
                    copyTransformedText(result)
                    onCopy?()
                }
            }

            return UIMenu(title: group.title, options: .displayInline, children: actions)
        }

        return UIMenu(title: NSLocalizedString("Copy As", comment: ""), image: UIImage(systemName: "wand.and.sparkles"), children: groups)
    }
}

/// Copies a transformed string, flagging the change so the clipboard monitor doesn't save it as a new clipping.
private func copyTransformedText(_ text: String)
{
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    CFNotificationCenterPostNotification(center, .ignoreNextPasteboardChange, nil, nil, true)

    UIPasteboard.general.string = text
}
