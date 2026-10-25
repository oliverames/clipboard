//
//  HistoryItemViews.swift
//  Clipboard
//
//  The two ways the history draws a clipping: a list row and a grid card.
//  Both are hosted in collection view cells through UIHostingConfiguration.
//

import SwiftUI

import ClipboardKit

/// What a row or card needs to draw one clipping. The view controller fills it in, so the cells stay cheap.
struct HistoryItemContent
{
    var item: PasteboardItem
    var kind: ClippingKind
    var title: AttributedString
    var subtitle: String?
    var thumbnail: UIImage?
    var icon: UIImage?
    var showsLocation: Bool
    var isLinkAddress: Bool
}

// MARK: - List row

struct HistoryRow: View
{
    var content: HistoryItemContent

    @Environment(\.dynamicTypeSize)
    private var dynamicTypeSize

    @ScaledMetric(relativeTo: .body)
    private var tileSize = 44.0

    var body: some View {
        let isAccessibilitySize = self.dynamicTypeSize.isAccessibilitySize
        let layout = isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .center, spacing: 12))

        layout {
            ClippingTile(kind: self.content.kind, icon: self.content.icon, thumbnail: self.content.thumbnail)
                .frame(width: self.tileSize, height: self.tileSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(self.content.title)
                    .font(self.content.kind.isCode ? .callout.monospaced() : .body)
                    .lineLimit(self.content.isLinkAddress ? 1 : (isAccessibilitySize ? 4 : 2))
                    .truncationMode(self.content.isLinkAddress ? .middle : .tail)

                HistoryMetadata(content: self.content)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Grid card

struct HistoryCard: View
{
    var content: HistoryItemContent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: kind and age, as in Paste's cards.
            HStack(spacing: 6) {
                Image(systemName: self.content.kind.symbolName)
                    .foregroundStyle(self.content.kind.color)
                Text(self.content.kind.title)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if self.content.item.isPinned
                {
                    Image(systemName: "pin.fill").foregroundStyle(.orange)
                }

                if self.content.item.isFavorite
                {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                }

                Text(self.content.item.ageText())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.caption)
            .imageScale(.small)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            self.preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color(uiColor: .separator).opacity(0.4), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let thumbnail = self.content.thumbnail
        {
            Color.clear
                .overlay {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
        }
        else if self.content.kind == .link
        {
            VStack(alignment: .leading, spacing: 8) {
                ClippingTile(kind: .link, icon: self.content.icon)
                    .frame(width: 40, height: 40)

                Text(self.content.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(3)
                    .truncationMode(self.content.isLinkAddress ? .middle : .tail)

                Spacer(minLength: 0)

                if let subtitle = self.content.subtitle
                {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding([.horizontal, .bottom], 12)
        }
        else
        {
            Text(self.content.title)
                .font(self.content.kind.isCode ? .caption.monospaced() : .subheadline)
                .padding([.horizontal, .bottom], 12)
                // The card's fixed height decides how many lines fit; a fade marks where the text continues.
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0.75), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                }
        }
    }
}

// MARK: - Shared

/// The second line of a row: state symbols, then the source or kind, then the age.
private struct HistoryMetadata: View
{
    var content: HistoryItemContent

    var body: some View {
        HStack(spacing: 5) {
            if self.content.item.isPinned
            {
                Image(systemName: "pin.fill").foregroundStyle(.orange)
            }

            if self.content.item.isFavorite
            {
                Image(systemName: "star.fill").foregroundStyle(.yellow)
            }

            if self.content.showsLocation
            {
                Image(systemName: "location.fill").foregroundStyle(.secondary)
            }

            Text([self.content.subtitle ?? self.content.kind.title, self.content.item.ageText()].joined(separator: " · "))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.footnote)
        .imageScale(.small)
    }
}

/// The filter chips above the history: one per content type.
struct FilterBar: View
{
    var selection: ContentFilter
    var onSelect: (ContentFilter) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(ContentFilter.allCases, id: \.self) { filter in
                    let isSelected = (filter == self.selection)

                    Button {
                        self.onSelect(filter)
                    } label: {
                        Label(filter.title, systemImage: filter.symbolName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(isSelected ? .accentColor : .secondary)
                    .background {
                        if isSelected
                        {
                            Capsule().fill(Color.accentColor.opacity(0.12))
                        }
                    }
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
    }
}
