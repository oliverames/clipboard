//
//  ClippingCell.swift
//  ClipboardKit
//
//  Created by Riley Testut on 5/25/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import SwiftUI
import CoreData

public struct ClippingCell: View
{
    @ObservedObject var pasteboardItem: PasteboardItem
    @ObservedObject private var linkPreviews = LinkPreviewStore.shared

    public init(pasteboardItem: PasteboardItem)
    {
        self.pasteboardItem = pasteboardItem
    }

    public var body: some View {
        let link = self.pasteboardItem.linkURL
        let preview = link.flatMap { self.linkPreviews.preview(for: $0) }
        let typeName = self.pasteboardItem.preferredRepresentation?.type.localizedName ?? NSLocalizedString("Unknown", comment: "")

        HStack(spacing: 12) {
            Group {
                if let icon = preview?.icon
                {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFit()
                }
                else
                {
                    Image(systemName: link == nil ? (self.pasteboardItem.preferredRepresentation?.type.symbolName ?? "doc") : "link")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                if let link
                {
                    Text(preview?.title ?? link.absoluteString)
                        .font(.body)
                        .lineLimit(preview?.title == nil ? 1 : 2)
                        .truncationMode(preview?.title == nil ? .middle : .tail)
                }
                else
                {
                    Text(self.pasteboardItem.contentText ?? typeName)
                        .font(.body)
                        .lineLimit(2)
                }

                Text((link?.host ?? typeName) + " · " + self.pasteboardItem.ageText())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .task(id: link) {
            guard let link else { return }
            LinkPreviewStore.shared.fetchPreviewIfNeeded(for: link)
        }
    }
}

struct ClippingCell_Previews: PreviewProvider
{
    static var previews: some View
    {
        Preview.prepare()

        let context = DatabaseManager.shared.persistentContainer.viewContext
        let date = Date().addingTimeInterval(-1 * 60 * 60)

        let item = PasteboardItem.make(item: "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum." as NSString, date: date, context: context)

        return ClippingCell(pasteboardItem: item)
            .environment(\.managedObjectContext, context)
            .previewLayout(.sizeThatFits)
    }
}
