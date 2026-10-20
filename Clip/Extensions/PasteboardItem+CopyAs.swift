//
//  PasteboardItem+CopyAs.swift
//  Clip
//

import UIKit

import ClipKit

extension PasteboardItem
{
    /// A "Copy As" menu that copies the clipping's text after a transformation.
    /// Transformations that can't apply to the text stay visible but disabled.
    func makeCopyAsMenu() -> UIMenu?
    {
        guard let text = self.contentText else { return nil }

        let actions: [UIMenuElement] = ClippingTransform.allCases.map { transform in
            let result = transform.apply(to: text)

            return UIAction(title: transform.title, attributes: result == nil ? .disabled : []) { _ in
                guard let result else { return }
                copyTransformedText(result)
            }
        }

        return UIMenu(title: NSLocalizedString("Copy As", comment: ""), image: UIImage(systemName: "doc.on.clipboard"), children: actions)
    }
}

/// Copies a transformed string, flagging the change so the clipboard monitor doesn't save it as a new clipping.
private func copyTransformedText(_ text: String)
{
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    CFNotificationCenterPostNotification(center, .ignoreNextPasteboardChange, nil, nil, true)

    UIPasteboard.general.string = text
}
