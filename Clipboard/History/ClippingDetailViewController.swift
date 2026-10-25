//
//  ClippingDetailViewController.swift
//  Clipboard
//
//  One clipping, full size, with its metadata, in the spirit of Pastebot's detail window.
//  Copy leads the bottom toolbar; favorite and pin toggle from the navigation bar.
//

import UIKit
import SwiftUI
import CoreLocation

import ClipboardKit

class ClippingDetailViewController: UIViewController
{
    private let pasteboardItem: PasteboardItem

    init(pasteboardItem: PasteboardItem)
    {
        self.pasteboardItem = pasteboardItem
        super.init(nibName: nil, bundle: nil)

        self.hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder)
    {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad()
    {
        super.viewDidLoad()

        self.view.backgroundColor = .systemGroupedBackground
        self.navigationItem.largeTitleDisplayMode = .never

        // The SwiftUI content is a child, so the hosting controller doesn't take over this screen's UIKit toolbar.
        let hostingController = ReservedRegionHostingController(rootView: ClippingDetailView(item: self.pasteboardItem))
        hostingController.view.backgroundColor = .clear
        self.addChild(hostingController)
        hostingController.view.frame = self.view.bounds
        hostingController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)

        self.updateBarItems()
    }

    override func viewWillAppear(_ animated: Bool)
    {
        super.viewWillAppear(animated)
        self.navigationController?.setToolbarHidden(false, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool)
    {
        super.viewWillDisappear(animated)
        self.navigationController?.setToolbarHidden(true, animated: animated)
    }
}

private extension ClippingDetailViewController
{
    var isTrashed: Bool { self.pasteboardItem.trashedDate != nil }

    func updateBarItems()
    {
        let item = self.pasteboardItem

        // Every item has a title: it shows in the overflow menu when the bar runs out of room, as on iPhone Duo.
        if self.isTrashed
        {
            self.navigationItem.rightBarButtonItems = []
        }
        else
        {
            let favoriteButton = UIBarButtonItem(title: item.isFavorite ? NSLocalizedString("Remove from Favorites", comment: "") : NSLocalizedString("Add to Favorites", comment: ""),
                                                 image: UIImage(systemName: item.isFavorite ? "star.fill" : "star"),
                                                 primaryAction: UIAction { [weak self] _ in self?.toggleFavorite() })
            favoriteButton.tintColor = item.isFavorite ? .systemYellow : nil

            let pinButton = UIBarButtonItem(title: item.isPinned ? NSLocalizedString("Unpin", comment: "") : NSLocalizedString("Pin to Top", comment: ""),
                                            image: UIImage(systemName: item.isPinned ? "pin.fill" : "pin"),
                                            primaryAction: UIAction { [weak self] _ in self?.togglePin() })
            pinButton.tintColor = item.isPinned ? .systemOrange : nil

            self.navigationItem.rightBarButtonItems = [favoriteButton, pinButton]
        }

        let copyButton = UIBarButtonItem(title: NSLocalizedString("Copy", comment: ""), image: UIImage(systemName: "doc.on.doc"), primaryAction: UIAction(title: NSLocalizedString("Copy", comment: "")) { [weak self] _ in
            self?.copyItem()
        })
        copyButton.style = .prominent
        copyButton.visibilityPriority = .high

        let shareButton = UIBarButtonItem(title: NSLocalizedString("Share", comment: ""), image: UIImage(systemName: "square.and.arrow.up"), target: self, action: #selector(ClippingDetailViewController.shareItem(_:)), menu: nil)

        var items = [UIBarButtonItem]()

        if self.isTrashed
        {
            let restoreButton = UIBarButtonItem(title: NSLocalizedString("Restore", comment: ""), image: UIImage(systemName: "arrow.uturn.backward"), primaryAction: UIAction { [weak self] _ in
                self?.restoreItem()
            })
            items = [restoreButton, .flexibleSpace(), shareButton, copyButton]
        }
        else
        {
            let trashButton = UIBarButtonItem(title: NSLocalizedString("Move to Trash", comment: ""), image: UIImage(systemName: "trash"), primaryAction: UIAction { [weak self] _ in
                self?.trashItem()
            })
            trashButton.visibilityPriority = .low

            items = [trashButton, .flexibleSpace(), shareButton]

            if let copyAsMenu = item.makeCopyAsMenu(onCopy: { [weak self] in self?.confirm() })
            {
                let copyAsButton = UIBarButtonItem(title: NSLocalizedString("Copy As", comment: ""), image: UIImage(systemName: "wand.and.sparkles"), target: nil, action: nil, menu: copyAsMenu)
                items.append(copyAsButton)
            }

            items.append(copyButton)
        }

        self.setToolbarItems(items, animated: false)
    }

    func save()
    {
        let context = DatabaseManager.shared.persistentContainer.viewContext
        guard context.hasChanges else { return }

        do
        {
            try context.save()
        }
        catch
        {
            let alertController = UIAlertController(title: NSLocalizedString("Couldn't Save Changes", comment: ""), message: error.localizedDescription, preferredStyle: .alert)
            alertController.addAction(.ok)
            self.present(alertController, animated: true)
        }
    }

    func copyItem()
    {
        UIPasteboard.general.copy(self.pasteboardItem)
        self.confirm()
    }

    func toggleFavorite()
    {
        self.pasteboardItem.isFavorite.toggle()
        self.save()
        Haptics.selection()
        self.updateBarItems()
    }

    func togglePin()
    {
        self.pasteboardItem.isPinned.toggle()
        self.save()
        Haptics.selection()
        self.updateBarItems()
    }

    func trashItem()
    {
        self.pasteboardItem.trashedDate = Date()
        self.save()
        Haptics.impact()
        self.navigationController?.popViewController(animated: true)
    }

    func restoreItem()
    {
        self.pasteboardItem.trashedDate = nil
        self.save()
        Haptics.success()
        self.navigationController?.popViewController(animated: true)
    }

    @objc func shareItem(_ sender: UIBarButtonItem)
    {
        let activityViewController = UIActivityViewController(activityItems: [self.pasteboardItem], applicationActivities: nil)
        activityViewController.popoverPresentationController?.sourceItem = sender
        self.present(activityViewController, animated: true)
    }
}

// MARK: - Content

struct ClippingDetailView: View
{
    @ObservedObject var item: PasteboardItem
    @ObservedObject private var linkPreviews = LinkPreviewStore.shared

    @Environment(\.dynamicTypeSize)
    private var dynamicTypeSize

    @ScaledMetric(relativeTo: .title2)
    private var tileSize = 52.0

    @State
    private var placeName: String?

    /// SwiftUI lays out all of a Text at once, so very long clippings show their start and say so.
    private static let displayLimit = 20_000

    var body: some View {
        let kind = ClippingKind(self.item)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                self.header(kind: kind)
                self.content(kind: kind)
                self.metadata(kind: kind)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .task {
            await self.lookUpPlace()
        }
    }

    // MARK: Header

    @ViewBuilder
    private func header(kind: ClippingKind) -> some View {
        let layout = self.dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 14))

        layout {
            ClippingTile(kind: kind, icon: self.item.linkURL.flatMap { self.linkPreviews.preview(for: $0)?.icon })
                .frame(width: self.tileSize, height: self.tileSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.title2.bold())

                Text(self.item.date.formatted(date: .complete, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Content

    @ViewBuilder
    private func content(kind: ClippingKind) -> some View {
        if let image = self.item.preferredRepresentation?.imageValue
        {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color(uiColor: .separator).opacity(0.5), lineWidth: 0.5)
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text("Image"))
        }
        else if let link = self.item.linkURL
        {
            let preview = self.linkPreviews.preview(for: link)

            VStack(alignment: .leading, spacing: 12) {
                if let title = preview?.title
                {
                    Text(title)
                        .font(.headline)
                }

                Text(link.absoluteString)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Link(destination: link) {
                    Label("Open in Browser", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        else
        {
            VStack(alignment: .leading, spacing: 10) {
                if kind.isCode
                {
                    // Code keeps its line structure; long lines scroll sideways instead of wrapping.
                    ScrollView(.horizontal) {
                        self.text(kind: kind)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .scrollIndicators(.automatic)
                }
                else
                {
                    self.text(kind: kind)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if (self.item.contentText?.count ?? 0) > Self.displayLimit
                {
                    Text("Showing the first 20,000 characters. Copy includes everything.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func text(kind: ClippingKind) -> Text
    {
        if kind == .richText, let attributedText = self.item.preferredRepresentation?.attributedStringValue,
           attributedText.length <= Self.displayLimit,
           var styled = try? AttributedString(attributedText, including: \.uiKit)
        {
            // Keep the clipping's own styling, but in colors that read in both light and dark mode.
            styled.uiKit.foregroundColor = nil
            styled.uiKit.backgroundColor = nil
            return Text(styled).foregroundColor(.primary)
        }

        let text = String((self.item.contentText ?? "").prefix(Self.displayLimit))
        return Text(text).font(kind.isCode ? .callout.monospaced() : .body)
    }

    // MARK: Metadata

    @ViewBuilder
    private func metadata(kind: ClippingKind) -> some View {
        let rows = self.details(kind: kind)

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { (index, row) in
                MetadataRow(title: row.title, value: row.value)

                if index < rows.count - 1
                {
                    Divider().padding(.leading, 16)
                }
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func details(kind: ClippingKind) -> [(title: String, value: String)]
    {
        let representation = self.item.preferredRepresentation

        var details = [(title: String, value: String)]()
        details.append((NSLocalizedString("Kind", comment: ""), kind.title))

        if representation?.type != .image, let text = self.item.contentText
        {
            let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            details.append((NSLocalizedString("Characters", comment: ""), text.count.formatted()))
            details.append((NSLocalizedString("Words", comment: ""), words.formatted()))
            details.append((NSLocalizedString("Size", comment: ""), ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file)))
        }

        if let image = representation?.imageValue
        {
            details.append((NSLocalizedString("Dimensions", comment: ""), "\(Int(image.size.width * image.scale)) × \(Int(image.size.height * image.scale))"))

            if let data = representation?.dataValue
            {
                details.append((NSLocalizedString("Size", comment: ""), ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))
            }
        }

        details.append((NSLocalizedString("Copied", comment: ""), self.item.date.formatted(date: .abbreviated, time: .shortened)))

        if let host = self.item.linkURL?.host()
        {
            details.append((NSLocalizedString("Source", comment: ""), host))
        }

        if !self.item.lists.isEmpty
        {
            let names = self.item.lists.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            details.append((NSLocalizedString("Lists", comment: ""), names.formatted(.list(type: .and))))
        }

        if self.item.location != nil
        {
            details.append((NSLocalizedString("Location", comment: ""), self.placeName ?? NSLocalizedString("Tagged", comment: "")))
        }

        return details
    }

    private func lookUpPlace() async
    {
        guard self.item.location != nil else { return }

        // A saved name shows at once; otherwise Apple Maps is asked once for this clipping and the answer is kept.
        self.placeName = PlaceNames.cachedName(for: self.item)
        guard self.placeName == nil else { return }

        self.placeName = await PlaceNames.name(for: self.item)
    }
}

/// A label and value. They sit side by side until text gets large, then the value moves under its label.
private struct MetadataRow: View
{
    var title: String
    var value: String

    @Environment(\.dynamicTypeSize)
    private var dynamicTypeSize

    var body: some View {
        let layout = self.dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))

        layout {
            Text(self.title)
                .foregroundStyle(.secondary)

            if !self.dynamicTypeSize.isAccessibilitySize
            {
                Spacer(minLength: 8)
            }

            Text(self.value)
                .layoutPriority(1)
                .multilineTextAlignment(self.dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}
