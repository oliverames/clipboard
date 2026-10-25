//
//  ClippingCell.swift
//  ClipboardKit
//
//  Created by Riley Testut on 5/25/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import SwiftUI
import CoreData

/// A clipping row for SwiftUI surfaces: the keyboard and the map's clipping sheet.
public struct ClippingCell: View
{
    @ObservedObject var pasteboardItem: PasteboardItem
    @ObservedObject private var linkPreviews = LinkPreviewStore.shared

    @Environment(\.dynamicTypeSize)
    private var dynamicTypeSize

    @ScaledMetric(relativeTo: .body)
    private var tileSize = 40.0

    private let lineLimit: Int

    public init(pasteboardItem: PasteboardItem, lineLimit: Int = 2)
    {
        self.pasteboardItem = pasteboardItem
        self.lineLimit = lineLimit
    }

    public var body: some View {
        let kind = ClippingKind(self.pasteboardItem)
        let link = self.pasteboardItem.linkURL
        let preview = link.flatMap { self.linkPreviews.preview(for: $0) }
        let title = preview?.title ?? link?.absoluteString ?? self.pasteboardItem.contentText ?? kind.title

        // At accessibility sizes the tile would squeeze the text into a sliver, so the text gets the full width.
        let layout = self.dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))

        layout {
            // No image thumbnails here: decoding full images would push the keyboard extension past its memory limit.
            ClippingTile(kind: kind, icon: preview?.icon)
                .frame(width: self.tileSize, height: self.tileSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(kind.isCode ? .body.monospaced() : .body)
                    .foregroundStyle(.primary)
                    .lineLimit(link != nil && preview?.title == nil ? 1 : self.lineLimit)
                    .truncationMode(link != nil && preview?.title == nil ? .middle : .tail)

                HStack(spacing: 4) {
                    if self.pasteboardItem.isPinned
                    {
                        Image(systemName: "pin.fill").foregroundStyle(.orange)
                    }

                    if self.pasteboardItem.isFavorite
                    {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                    }

                    Text(self.metadataText(kind: kind, link: link))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.footnote)
                .imageScale(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.pasteboardItem.accessibilityDescription(kind: kind, title: title))
        .task(id: link) {
            guard let link else { return }
            LinkPreviewStore.shared.fetchPreviewIfNeeded(for: link)
        }
    }

    private func metadataText(kind: ClippingKind, link: URL?) -> String
    {
        let source = link?.host() ?? kind.title
        return source + " · " + self.pasteboardItem.ageText()
    }
}

/// The square that leads a clipping row: a thumbnail, a site icon, or the kind's symbol on its accent color.
public struct ClippingTile: View
{
    var kind: ClippingKind
    var icon: UIImage?
    var thumbnail: UIImage?

    public init(kind: ClippingKind, icon: UIImage? = nil, thumbnail: UIImage? = nil)
    {
        self.kind = kind
        self.icon = icon
        self.thumbnail = thumbnail
    }

    public var body: some View {
        GeometryReader { proxy in
            let radius = proxy.size.width * 0.25

            ZStack {
                if let image = self.thumbnail ?? self.icon
                {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
                else
                {
                    self.kind.color.opacity(0.16)

                    Image(systemName: self.kind.symbolName)
                        .font(.system(size: proxy.size.width * 0.42, weight: .semibold))
                        .foregroundStyle(self.kind.color)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
            }
        }
        .accessibilityHidden(true)
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
