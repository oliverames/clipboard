//
//  HistoryViewController.swift
//  Clipboard
//
//  Created by Riley Testut on 6/10/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import UIKit
import SwiftUI
import Combine
import CoreData
import CoreLocation
import Contacts

import ClipboardKit
import Roxas

/// The groups of clippings the history screen can show.
enum HistoryCollection: Equatable
{
    case history
    case favorites
    case trash
    case list(NSManagedObjectID)
}

/// The content types the history screen can filter to.
enum ContentFilter: CaseIterable
{
    case all
    case text
    case richText
    case image
    case link
    case code

    var title: String {
        switch self
        {
        case .all: return NSLocalizedString("All", comment: "")
        case .text: return NSLocalizedString("Text", comment: "")
        case .richText: return NSLocalizedString("Rich Text", comment: "")
        case .image: return NSLocalizedString("Images", comment: "")
        case .link: return NSLocalizedString("Links", comment: "")
        case .code: return NSLocalizedString("Code", comment: "")
        }
    }

    var symbolName: String {
        switch self
        {
        case .all: return "square.grid.2x2"
        case .text: return "text.alignleft"
        case .richText: return "textformat"
        case .image: return "photo"
        case .link: return "link"
        case .code: return "chevron.left.forwardslash.chevron.right"
        }
    }

    func matches(_ kind: ClippingKind) -> Bool
    {
        switch (self, kind)
        {
        case (.all, _): return true
        case (.text, .text): return true
        case (.richText, .richText): return true
        case (.image, .image): return true
        case (.link, .link): return true
        case (.code, .code): return true
        default: return false
        }
    }
}

/// How the history lays out clippings.
enum HistoryLayout: String
{
    case list
    case grid

    private static let defaultsKey = "HistoryLayout"

    static var saved: HistoryLayout {
        get { UserDefaults.standard.string(forKey: self.defaultsKey).flatMap(HistoryLayout.init(rawValue:)) ?? .list }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: self.defaultsKey) }
    }
}

class HistoryViewController: UIViewController
{
    fileprivate enum Section: Hashable
    {
        case main
    }

    private static let filterBarKind = "FilterBar"

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, NSManagedObjectID>!
    private var fetchedResultsController: NSFetchedResultsController<PasteboardItem>!

    private var collection = HistoryCollection.history
    private var contentFilter = ContentFilter.all
    private var layoutMode = HistoryLayout.saved
    private var searchText: String?
    private var matches = [NSManagedObjectID: FuzzyMatch]()

    /// Code detection is the costly part of classifying a clipping, and a clipping's content never changes.
    private var kinds = [NSManagedObjectID: ClippingKind]()

    private let thumbnailCache = NSCache<NSManagedObjectID, UIImage>()
    private var pendingThumbnails = Set<NSManagedObjectID>()

    private var defaultTitle: String?
    private var isEmpty = false

    private let _undoManager = UndoManager()

    private var updateTimer: Timer?
    private var fetchLimitSettingObservation: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()

    override var undoManager: UndoManager? {
        return _undoManager
    }

    override var canBecomeFirstResponder: Bool {
        return true
    }

    override func viewDidLoad()
    {
        super.viewDidLoad()

        self.defaultTitle = self.navigationItem.title

        self.collectionView = UICollectionView(frame: self.view.bounds, collectionViewLayout: self.makeLayout())
        self.collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.collectionView.delegate = self
        self.collectionView.keyboardDismissMode = .onDrag
        self.view.addSubview(self.collectionView)
        self.updateBackgroundColor()

        let searchController = UISearchController(searchResultsController: nil)
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchResultsUpdater = self
        searchController.searchBar.placeholder = NSLocalizedString("Search Clippings", comment: "")
        self.navigationItem.searchController = searchController
        self.navigationItem.hidesSearchBarWhenScrolling = false
        self.definesPresentationContext = true

        self.dataSource = self.makeDataSource()
        self.updateFetchedResultsController()

        DatabaseManager.shared.persistentContainer.viewContext.undoManager = self.undoManager

        NotificationCenter.default.addObserver(self, selector: #selector(HistoryViewController.didEnterBackground(_:)), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(HistoryViewController.willEnterForeground(_:)), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(HistoryViewController.settingsDidChange(_:)), name: .settingsDidChange, object: nil)

        self.fetchLimitSettingObservation = UserDefaults.shared.observe(\.historyLimit) { [weak self] (defaults, change) in
            DispatchQueue.main.async {
                self?.applySnapshot(animated: true)
            }
        }

        LinkPreviewStore.shared.$previews
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reconfigureVisibleItems() }
            .store(in: &self.cancellables)

        self.navigationController?.tabBarItem.title = NSLocalizedString("History", comment: "")
        self.navigationController?.tabBarItem.image = UIImage(systemName: "clock")
        self.navigationController?.tabBarItem.selectedImage = UIImage(systemName: "clock.fill")

        self.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            // Grid columns depend on the text size, so rebuild the layout when it changes.
            self.collectionView.setCollectionViewLayout(self.makeLayout(), animated: false)
        }

        self.startUpdating()
    }

    override func viewDidLayoutSubviews()
    {
        super.viewDidLayoutSubviews()

        // The outer display reserves a column along one edge for the status bar and toolbar, so content stops short of it.
        self.collectionView.applyReservedRegionInsets()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator)
    {
        super.viewWillTransition(to: size, with: coordinator)

        coordinator.animate(alongsideTransition: { _ in
            self.collectionView.collectionViewLayout.invalidateLayout()
        })
    }

    override func viewDidAppear(_ animated: Bool)
    {
        super.viewDidAppear(animated)

        self.becomeFirstResponder()
        self.presentOnboardingIfNeeded()

        #if DEBUG
        self.showDemoScreenIfRequested()
        #endif
    }

    override func viewWillDisappear(_ animated: Bool)
    {
        super.viewWillDisappear(animated)

        self.resignFirstResponder()
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState)
    {
        guard self.isEmpty else
        {
            self.contentUnavailableConfiguration = nil
            return
        }

        var configuration: UIContentUnavailableConfiguration

        if let searchText, !searchText.isEmpty
        {
            configuration = .search()
            configuration.secondaryText = NSLocalizedString("Check the spelling or try a different search.", comment: "")
        }
        else if self.contentFilter != .all
        {
            configuration = .empty()
            configuration.image = UIImage(systemName: self.contentFilter.symbolName)
            configuration.text = String(format: NSLocalizedString("No %@", comment: "No [content type], such as No Links"), self.contentFilter.title)
            configuration.secondaryText = NSLocalizedString("Nothing here matches this filter.", comment: "")

            var button = UIButton.Configuration.glass()
            button.title = NSLocalizedString("Show All", comment: "")
            configuration.button = button
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in
                self?.setContentFilter(.all)
            }
        }
        else
        {
            configuration = .empty()

            switch self.collection
            {
            case .history:
                configuration.image = UIImage(systemName: "doc.on.clipboard")
                configuration.text = NSLocalizedString("No Clippings Yet", comment: "")
                configuration.secondaryText = NSLocalizedString("Copy something in any app, and it appears here.", comment: "")

                var button = UIButton.Configuration.glass()
                button.title = NSLocalizedString("Set Up Capture", comment: "")
                configuration.button = button
                configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in
                    self?.presentOnboarding()
                }

            case .favorites:
                configuration.image = UIImage(systemName: "star")
                configuration.text = NSLocalizedString("No Favorites", comment: "")
                configuration.secondaryText = NSLocalizedString("Swipe left on a clipping, or touch and hold it, to add it to Favorites.", comment: "")

            case .trash:
                configuration.image = UIImage(systemName: "trash")
                configuration.text = NSLocalizedString("Trash Is Empty", comment: "")
                configuration.secondaryText = NSLocalizedString("Clippings you delete stay here until you empty the Trash.", comment: "")

            case .list:
                configuration.image = UIImage(systemName: "list.bullet.rectangle")
                configuration.text = NSLocalizedString("Empty List", comment: "")
                configuration.secondaryText = NSLocalizedString("Touch and hold a clipping, then choose Add to List.", comment: "")
            }
        }

        self.contentUnavailableConfiguration = configuration
    }
}

// MARK: - Layout and data

private extension HistoryViewController
{
    func makeLayout() -> UICollectionViewLayout
    {
        let headerSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(52))
        let header = NSCollectionLayoutBoundarySupplementaryItem(layoutSize: headerSize, elementKind: Self.filterBarKind, alignment: .top)

        switch self.layoutMode
        {
        case .list:
            return UICollectionViewCompositionalLayout { [weak self] (sectionIndex, environment) in
                var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
                configuration.showsSeparators = true
                configuration.leadingSwipeActionsConfigurationProvider = { indexPath in self?.leadingSwipeActions(for: indexPath) }
                configuration.trailingSwipeActionsConfigurationProvider = { indexPath in self?.trailingSwipeActions(for: indexPath) }
                configuration.itemSeparatorHandler = { indexPath, separatorConfiguration in
                    // Separators start where the text does, as in Mail and Messages.
                    var separatorConfiguration = separatorConfiguration
                    separatorConfiguration.bottomSeparatorInsets.leading = environment.traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 16 : 72
                    return separatorConfiguration
                }

                let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
                section.boundarySupplementaryItems = [header]
                return section
            }

        case .grid:
            return UICollectionViewCompositionalLayout { (sectionIndex, environment) in
                let traits = environment.traitCollection
                let width = environment.container.effectiveContentSize.width

                // Cards stay at least 160 points wide, wider as text grows, and drop to one column at accessibility sizes.
                let minimumWidth = UIFontMetrics(forTextStyle: .body).scaledValue(for: 160, compatibleWith: traits)
                let columns = traits.preferredContentSizeCategory.isAccessibilityCategory ? 1 : max(2, Int((width - 16) / (minimumWidth + 12)))
                let cardHeight = UIFontMetrics(forTextStyle: .subheadline).scaledValue(for: 168, compatibleWith: traits)

                let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0 / CGFloat(columns)), heightDimension: .fractionalHeight(1))
                let item = NSCollectionLayoutItem(layoutSize: itemSize)

                let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(cardHeight))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, repeatingSubitem: item, count: columns)
                group.interItemSpacing = .fixed(12)

                let section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = 12
                section.contentInsetsReference = .readableContent
                section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 24, trailing: 0)
                section.boundarySupplementaryItems = [header]
                return section
            }
        }
    }

    func makeDataSource() -> UICollectionViewDiffableDataSource<Section, NSManagedObjectID>
    {
        let listRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, NSManagedObjectID> { [weak self] (cell, indexPath, objectID) in
            guard let self, let content = self.content(for: objectID) else { return }

            cell.contentConfiguration = UIHostingConfiguration { HistoryRow(content: content) }
                .margins(.horizontal, 16)
                .margins(.vertical, 8)
            self.configureAccessibility(of: cell, content: content)
        }

        let gridRegistration = UICollectionView.CellRegistration<UICollectionViewCell, NSManagedObjectID> { [weak self] (cell, indexPath, objectID) in
            guard let self, let content = self.content(for: objectID) else { return }

            cell.contentConfiguration = UIHostingConfiguration { HistoryCard(content: content) }
                .margins(.all, 0)
            self.configureAccessibility(of: cell, content: content)
        }

        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: Self.filterBarKind) { [weak self] (header, kind, indexPath) in
            guard let self else { return }

            header.contentConfiguration = UIHostingConfiguration {
                FilterBar(selection: self.contentFilter) { [weak self] filter in
                    self?.setContentFilter(filter)
                }
            }
            .margins(.horizontal, self.layoutMode == .grid ? 0 : 16)
            .margins(.vertical, 0)
            header.backgroundConfiguration = .clear()
        }

        let dataSource = UICollectionViewDiffableDataSource<Section, NSManagedObjectID>(collectionView: self.collectionView) { [weak self] (collectionView, indexPath, objectID) in
            switch self?.layoutMode ?? .list
            {
            case .list: return collectionView.dequeueConfiguredReusableCell(using: listRegistration, for: indexPath, item: objectID)
            case .grid: return collectionView.dequeueConfiguredReusableCell(using: gridRegistration, for: indexPath, item: objectID)
            }
        }

        dataSource.supplementaryViewProvider = { (collectionView, kind, indexPath) in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }

        return dataSource
    }

    func configureAccessibility(of cell: UICollectionViewCell, content: HistoryItemContent)
    {
        let plainTitle = String(content.title.characters)
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = content.item.accessibilityDescription(kind: content.kind, title: content.subtitle.map { plainTitle + ", " + $0 } ?? plainTitle)
        cell.accessibilityHint = NSLocalizedString("Opens the clipping.", comment: "")
        cell.accessibilityCustomActions = self.accessibilityActions(for: content.item)
    }

    /// Fetches the current collection and keeps the list in sync with Core Data changes.
    func updateFetchedResultsController()
    {
        let fetchRequest = self.fetchRequest(for: self.collection)
        fetchRequest.returnsObjectsAsFaults = false
        fetchRequest.relationshipKeyPathsForPrefetching = [#keyPath(PasteboardItem.preferredRepresentation)]

        let fetchedResultsController = NSFetchedResultsController(fetchRequest: fetchRequest, managedObjectContext: DatabaseManager.shared.persistentContainer.viewContext, sectionNameKeyPath: nil, cacheName: nil)
        fetchedResultsController.delegate = self
        self.fetchedResultsController = fetchedResultsController

        do
        {
            try fetchedResultsController.performFetch()
        }
        catch
        {
            print("Failed to fetch clippings.", error)
        }

        self.applySnapshot(animated: false)
        self.updateNavigationItems()
    }

    func fetchRequest(for collection: HistoryCollection) -> NSFetchRequest<PasteboardItem>
    {
        switch collection
        {
        case .history:
            // The history limit applies after filtering, so visibleItems() trims the results instead of the fetch.
            let fetchRequest = PasteboardItem.historyFetchRequest()
            fetchRequest.fetchLimit = 0
            return fetchRequest

        case .favorites:
            let fetchRequest = PasteboardItem.fetchRequest() as NSFetchRequest<PasteboardItem>
            fetchRequest.predicate = NSPredicate(format: "isMarkedForDeletion == NO AND trashedDate == nil AND isFavorite == YES")
            fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \PasteboardItem.isPinned, ascending: false), NSSortDescriptor(keyPath: \PasteboardItem.date, ascending: false)]
            return fetchRequest

        case .trash:
            return PasteboardItem.trashFetchRequest()

        case .list(let objectID):
            let fetchRequest = PasteboardItem.fetchRequest() as NSFetchRequest<PasteboardItem>
            let list = try? DatabaseManager.shared.persistentContainer.viewContext.existingObject(with: objectID) as? ClippingList
            fetchRequest.predicate = NSPredicate(format: "isMarkedForDeletion == NO AND trashedDate == nil AND ANY lists == %@", list ?? NSNull())
            fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \PasteboardItem.isPinned, ascending: false), NSSortDescriptor(keyPath: \PasteboardItem.date, ascending: false)]
            return fetchRequest
        }
    }

    /// The clippings the list shows: the collection, narrowed by content type, then ranked by the search.
    func visibleItems() -> [PasteboardItem]
    {
        self.matches.removeAll()

        var items = self.fetchedResultsController.fetchedObjects ?? []

        if self.collection == .history
        {
            items = Array(items.prefix(UserDefaults.shared.historyLimit.rawValue))
        }

        items = items.filter { self.contentFilter.matches(self.kind(for: $0)) }

        guard let searchText = self.searchText?.trimmingCharacters(in: .whitespacesAndNewlines), !searchText.isEmpty else { return items }

        var scoredItems = [(item: PasteboardItem, score: Int)]()

        for item in items
        {
            guard let text = self.displayText(for: item), let match = FuzzyMatcher.match(searchText, in: text) else { continue }

            self.matches[item.objectID] = match
            scoredItems.append((item, match.score))
        }

        return scoredItems.sorted { $0.score > $1.score }.map { $0.item }
    }

    func kind(for item: PasteboardItem) -> ClippingKind
    {
        if let kind = self.kinds[item.objectID]
        {
            return kind
        }

        let kind = ClippingKind(item)
        self.kinds[item.objectID] = kind
        return kind
    }

    /// The text a row shows before any link preview arrives, which is also what search matches.
    func displayText(for item: PasteboardItem) -> String?
    {
        return item.linkURL?.absoluteString ?? item.contentText
    }

    func applySnapshot(animated: Bool)
    {
        let items = self.visibleItems()
        let objectIDs = items.map { $0.objectID }

        var snapshot = NSDiffableDataSourceSnapshot<Section, NSManagedObjectID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(objectIDs)

        // Items keep their identity when their contents change, so reconfigure the ones that already exist.
        let existingObjectIDs = Set(self.dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(objectIDs.filter { existingObjectIDs.contains($0) })

        self.dataSource.apply(snapshot, animatingDifferences: animated && !UIAccessibility.isReduceMotionEnabled)

        self.isEmpty = objectIDs.isEmpty
        self.setNeedsUpdateContentUnavailableConfiguration()
    }

    func item(withObjectID objectID: NSManagedObjectID) -> PasteboardItem?
    {
        return try? DatabaseManager.shared.persistentContainer.viewContext.existingObject(with: objectID) as? PasteboardItem
    }

    func item(at indexPath: IndexPath) -> PasteboardItem?
    {
        guard let objectID = self.dataSource.itemIdentifier(for: indexPath) else { return nil }
        return self.item(withObjectID: objectID)
    }

    func content(for objectID: NSManagedObjectID) -> HistoryItemContent?
    {
        guard let item = self.item(withObjectID: objectID) else { return nil }

        let kind = self.kind(for: item)
        let match = self.matches[objectID]

        var title: String
        var subtitle: String?
        var icon: UIImage?
        var isLinkAddress = false

        if let link = item.linkURL
        {
            LinkPreviewStore.shared.fetchPreviewIfNeeded(for: link)
            let preview = LinkPreviewStore.shared.preview(for: link)

            icon = preview?.icon
            subtitle = link.host()

            if let previewTitle = preview?.title
            {
                title = previewTitle
            }
            else
            {
                // Raw addresses keep a single line so the middle of the address stays visible.
                title = link.absoluteString
                isLinkAddress = true
            }
        }
        else
        {
            title = item.contentText ?? kind.title

            // Collapse runs of whitespace so a multi-line clipping fills its preview instead of showing blank lines.
            if kind != .image, !kind.isCode
            {
                title = title.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            }

            if kind == .image
            {
                subtitle = item.preferredRepresentation?.imageValue.map { "\(Int($0.size.width * $0.scale)) × \(Int($0.size.height * $0.scale))" }
            }
        }

        // Search hits are bolded only where the shown text is the text that was searched.
        let attributedTitle: AttributedString
        if let match, !match.ranges.isEmpty, title == self.displayText(for: item)
        {
            attributedTitle = self.attributedText(for: title, match: match)
        }
        else
        {
            attributedTitle = AttributedString(title)
        }

        return HistoryItemContent(item: item,
                                  kind: kind,
                                  title: attributedTitle,
                                  subtitle: subtitle,
                                  thumbnail: kind == .image ? self.thumbnail(for: item) : nil,
                                  icon: icon,
                                  showsLocation: UserDefaults.shared.showLocationIcon && item.location != nil,
                                  isLinkAddress: isLinkAddress)
    }

    /// Marks the characters a search matched, the way Spotlight and Mail mark search hits.
    func attributedText(for text: String, match: FuzzyMatch) -> AttributedString
    {
        let attributedText = NSMutableAttributedString(string: text)

        for range in match.ranges
        {
            let nsRange = NSRange(range, in: text)
            attributedText.addAttribute(.foregroundColor, value: UIColor.tintColor, range: nsRange)
            attributedText.addAttribute(.font, value: UIFont.preferredFont(forTextStyle: .headline), range: nsRange)
        }

        var result = (try? AttributedString(attributedText, including: \.uiKit)) ?? AttributedString(text)

        // SwiftUI reads its own attribute scope, so carry the bold and tint across.
        for run in result.runs where run.uiKit.foregroundColor != nil
        {
            result[run.range].foregroundColor = Color.accentColor
            result[run.range].font = .body.weight(.bold)
        }

        return result
    }

    /// Returns a cached thumbnail, or decodes one in the background and reconfigures the item when it's ready.
    func thumbnail(for item: PasteboardItem) -> UIImage?
    {
        let objectID = item.objectID

        if let image = self.thumbnailCache.object(forKey: objectID)
        {
            return image
        }

        guard !self.pendingThumbnails.contains(objectID), let data = item.preferredRepresentation?.dataValue else { return nil }
        self.pendingThumbnails.insert(objectID)

        DispatchQueue.global(qos: .userInitiated).async {
            let image = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 600, height: 600))

            DispatchQueue.main.async {
                self.pendingThumbnails.remove(objectID)

                guard let image else { return }

                self.thumbnailCache.setObject(image, forKey: objectID)
                self.reconfigureItems([objectID])
            }
        }

        return nil
    }

    func reconfigureItems(_ objectIDs: [NSManagedObjectID])
    {
        var snapshot = self.dataSource.snapshot()
        let objectIDs = objectIDs.filter { snapshot.itemIdentifiers.contains($0) }
        guard !objectIDs.isEmpty else { return }

        snapshot.reconfigureItems(objectIDs)
        self.dataSource.apply(snapshot, animatingDifferences: false)
    }

    func reconfigureVisibleItems()
    {
        // The diffable data source owns the collection view, so items must be reconfigured through its snapshot.
        let objectIDs = self.collectionView.indexPathsForVisibleItems.compactMap { self.dataSource.itemIdentifier(for: $0) }
        self.reconfigureItems(objectIDs)
    }

    func refreshFilterBar()
    {
        var snapshot = self.dataSource.snapshot()
        guard !snapshot.sectionIdentifiers.isEmpty else { return }

        snapshot.reloadSections([.main])
        self.dataSource.apply(snapshot, animatingDifferences: false)
    }

    func setContentFilter(_ filter: ContentFilter)
    {
        guard filter != self.contentFilter else { return }

        Haptics.selection()
        self.contentFilter = filter
        self.applySnapshot(animated: true)
        self.refreshFilterBar()
    }

    func updateBackgroundColor()
    {
        // Cards need a grouped background to stand on; rows sit on the plain one.
        let color: UIColor = (self.layoutMode == .grid) ? .systemGroupedBackground : .systemBackground
        self.view.backgroundColor = color
        self.collectionView.backgroundColor = color
    }

    func setLayoutMode(_ layoutMode: HistoryLayout)
    {
        guard layoutMode != self.layoutMode else { return }

        Haptics.selection()
        self.layoutMode = layoutMode
        HistoryLayout.saved = layoutMode

        // Cells change type with the layout, so rebuild every item rather than morphing rows into cards.
        self.collectionView.setCollectionViewLayout(self.makeLayout(), animated: false)
        self.updateBackgroundColor()

        var snapshot = self.dataSource.snapshot()
        snapshot.reloadSections(snapshot.sectionIdentifiers)
        self.dataSource.apply(snapshot, animatingDifferences: false)

        self.updateNavigationItems()
    }

    func share(_ item: PasteboardItem, from sourceView: UIView?)
    {
        let activityViewController = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        activityViewController.popoverPresentationController?.sourceView = sourceView ?? self.view
        activityViewController.popoverPresentationController?.sourceRect = sourceView?.bounds ?? CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
        self.present(activityViewController, animated: true, completion: nil)
    }

    func showLocation(_ location: CLLocation)
    {
        let geocoder = CLGeocoder()
        geocoder.reverseGeocodeLocation(location) { (placemarks, error) in
            DispatchQueue.main.async {
                let title: String
                let message: String?

                if let placemarks, let placemark = placemarks.first,
                   let postalAddress = placemark.postalAddress?.mutableCopy() as? CNMutablePostalAddress
                {
                    // The location isn't precise, so don't pretend that it is by showing street address.
                    postalAddress.street = ""
                    postalAddress.subLocality = ""

                    let formatter = CNPostalAddressFormatter()

                    if let sublocality = placemark.subLocality
                    {
                        title = sublocality + "\n" + formatter.string(from: postalAddress)
                    }
                    else
                    {
                        title = formatter.string(from: postalAddress)
                    }

                    message = NSLocalizedString("Copied near this place.", comment: "")
                }
                else if let error
                {
                    title = NSLocalizedString("Couldn't Look Up Location", comment: "")
                    message = error.localizedDescription + "\n\n" + "\(location.coordinate.latitude), \(location.coordinate.longitude)"
                }
                else
                {
                    title = "\(location.coordinate.latitude), \(location.coordinate.longitude)"
                    message = nil
                }

                let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
                alertController.addAction(.ok)
                self.present(alertController, animated: true)
            }
        }
    }

    func startUpdating()
    {
        self.stopUpdating()

        // Ages read in minutes, so a refresh every half minute keeps them current without redrawing every second.
        self.updateTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] (timer) in
            self?.reconfigureVisibleItems()
        }
    }

    func stopUpdating()
    {
        self.updateTimer?.invalidate()
        self.updateTimer = nil
    }
}

// MARK: - Navigation

private extension HistoryViewController
{
    func updateNavigationItems()
    {
        // Each item has a title as well as a symbol: the title appears in the overflow menu when the bar runs out of
        // room, as on iPhone Duo's outer display, and VoiceOver reads it.
        let settingsButton = UIBarButtonItem(title: NSLocalizedString("Settings", comment: ""), image: UIImage(systemName: "gearshape"), target: self, action: #selector(HistoryViewController.showSettings(_:)), menu: nil)
        settingsButton.visibilityPriority = .low

        let layoutButton: UIBarButtonItem
        switch self.layoutMode
        {
        case .list:
            layoutButton = UIBarButtonItem(title: NSLocalizedString("View as Grid", comment: ""), image: UIImage(systemName: "square.grid.2x2"), primaryAction: UIAction { [weak self] _ in
                self?.setLayoutMode(.grid)
            })

        case .grid:
            layoutButton = UIBarButtonItem(title: NSLocalizedString("View as List", comment: ""), image: UIImage(systemName: "list.bullet"), primaryAction: UIAction { [weak self] _ in
                self?.setLayoutMode(.list)
            })
        }

        self.navigationItem.rightBarButtonItems = [settingsButton, layoutButton]

        // The collection switcher leads, so where you are and how to go elsewhere sit together.
        let collectionsButton = UIBarButtonItem(title: NSLocalizedString("Collections", comment: ""), image: UIImage(systemName: "tray.2"), target: nil, action: nil, menu: self.makeCollectionsMenu())
        collectionsButton.visibilityPriority = .high

        var leftItems = [collectionsButton]

        switch self.collection
        {
        case .history, .favorites:
            break

        case .trash:
            let emptyButton = UIBarButtonItem(title: NSLocalizedString("Empty Trash", comment: ""), image: UIImage(systemName: "trash.slash"), target: self, action: #selector(HistoryViewController.emptyTrashTapped(_:)), menu: nil)
            emptyButton.tintColor = .systemRed
            emptyButton.isEnabled = !(self.fetchedResultsController.fetchedObjects ?? []).isEmpty
            leftItems.append(emptyButton)

        case .list:
            let listMenu = UIMenu(children: [
                UIAction(title: NSLocalizedString("Rename List…", comment: ""), image: UIImage(systemName: "pencil")) { [weak self] _ in
                    self?.renameCurrentList()
                },
                UIAction(title: NSLocalizedString("Delete List…", comment: ""), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.deleteCurrentList()
                }
            ])

            // The ellipsis is reserved for the system overflow menu on iPhone Duo, so this menu gets its own symbol.
            leftItems.append(UIBarButtonItem(title: NSLocalizedString("List Options", comment: ""), image: UIImage(systemName: "list.bullet.rectangle"), target: nil, action: nil, menu: listMenu))
        }

        self.navigationItem.leftBarButtonItems = leftItems
    }

    func symbolName(for collection: HistoryCollection) -> String
    {
        switch collection
        {
        case .history: return "tray.full"
        case .favorites: return "star"
        case .trash: return "trash"
        case .list: return "list.bullet.rectangle"
        }
    }

    func makeCollectionsMenu() -> UIMenu
    {
        let collections: [(collection: HistoryCollection, title: String)] = [
            (.history, NSLocalizedString("All Clippings", comment: "")),
            (.favorites, NSLocalizedString("Favorites", comment: ""))
        ]

        let collectionActions: [UIMenuElement] = collections.map { (collection, title) in
            UIAction(title: title, image: UIImage(systemName: self.symbolName(for: collection)), state: self.collection == collection ? .on : .off) { [weak self] _ in
                self?.select(collection: collection)
            }
        }

        let listsMenu = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self = self else { return completion([]) }

            var listActions: [UIMenuElement] = self.fetchLists().map { list in
                let count = list.items.filter { $0.trashedDate == nil && !$0.isMarkedForDeletion }.count
                let subtitle = String.localizedStringWithFormat(NSLocalizedString(count == 1 ? "%d clipping" : "%d clippings", comment: ""), count)
                return UIAction(title: list.name, subtitle: subtitle, image: UIImage(systemName: "list.bullet.rectangle"), state: self.collection == .list(list.objectID) ? .on : .off) { [weak self] _ in
                    self?.select(collection: .list(list.objectID))
                }
            }

            listActions.append(UIAction(title: NSLocalizedString("New List…", comment: ""), image: UIImage(systemName: "plus")) { [weak self] _ in
                self?.presentNewList(adding: nil)
            })

            completion([UIMenu(title: NSLocalizedString("Lists", comment: ""), options: .displayInline, children: listActions)])
        }

        let trashAction = UIAction(title: NSLocalizedString("Trash", comment: ""), image: UIImage(systemName: "trash"), state: self.collection == .trash ? .on : .off) { [weak self] _ in
            self?.select(collection: .trash)
        }

        return UIMenu(title: NSLocalizedString("Collections", comment: ""), children: [
            UIMenu(options: .displayInline, children: collectionActions),
            listsMenu,
            UIMenu(options: .displayInline, children: [trashAction])
        ])
    }

    func select(collection: HistoryCollection)
    {
        if collection != self.collection
        {
            Haptics.selection()
        }

        self.collection = collection
        self.navigationItem.title = self.title(for: collection)
        self.updateFetchedResultsController()
        self.collectionView.setContentOffset(CGPoint(x: 0, y: -self.collectionView.adjustedContentInset.top), animated: false)
    }

    func title(for collection: HistoryCollection) -> String?
    {
        switch collection
        {
        case .history: return self.defaultTitle
        case .favorites: return NSLocalizedString("Favorites", comment: "")
        case .trash: return NSLocalizedString("Trash", comment: "")
        case .list: return self.currentList()?.name
        }
    }

    func currentList() -> ClippingList?
    {
        guard case .list(let objectID) = self.collection else { return nil }
        return try? DatabaseManager.shared.persistentContainer.viewContext.existingObject(with: objectID) as? ClippingList
    }

    func fetchLists() -> [ClippingList]
    {
        let fetchRequest = ClippingList.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: #keyPath(ClippingList.name), ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))]
        return (try? DatabaseManager.shared.persistentContainer.viewContext.fetch(fetchRequest)) ?? []
    }

    func presentNewList(adding item: PasteboardItem?)
    {
        let alertController = UIAlertController(title: NSLocalizedString("New List", comment: ""), message: nil, preferredStyle: .alert)
        alertController.addTextField { (textField) in
            textField.placeholder = NSLocalizedString("Name", comment: "")
            textField.autocapitalizationType = .words
            textField.clearButtonMode = .whileEditing
        }
        alertController.addAction(.cancel)

        alertController.addAction(UIAlertAction(title: NSLocalizedString("Create", comment: ""), style: .default) { [weak self, weak alertController] _ in
            let name = alertController?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return }

            let list = ClippingList(name: name, context: DatabaseManager.shared.persistentContainer.viewContext)
            item?.mutableSetValue(forKey: "lists").add(list)
            self?.saveChanges()

            // Save before showing the list, so the list has the permanent object ID its collection needs.
            if item == nil
            {
                self?.select(collection: .list(list.objectID))
            }
            else
            {
                self?.confirm(String(format: NSLocalizedString("Added to %@", comment: ""), name), systemImage: "text.badge.plus")
            }
        })

        self.present(alertController, animated: true)
    }

    func renameCurrentList()
    {
        guard let list = self.currentList() else { return }

        let alertController = UIAlertController(title: NSLocalizedString("Rename List", comment: ""), message: nil, preferredStyle: .alert)
        alertController.addTextField { (textField) in
            textField.text = list.name
            textField.autocapitalizationType = .words
            textField.clearButtonMode = .whileEditing
        }
        alertController.addAction(.cancel)

        alertController.addAction(UIAlertAction(title: NSLocalizedString("Save", comment: ""), style: .default) { [weak self, weak alertController] _ in
            guard let name = alertController?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }

            list.name = name
            self?.saveChanges()
            self?.navigationItem.title = name
        })

        self.present(alertController, animated: true)
    }

    func deleteCurrentList()
    {
        guard let list = self.currentList() else { return }

        self.confirm(title: String(format: NSLocalizedString("Delete “%@”?", comment: ""), list.name),
                     message: NSLocalizedString("The clippings in this list stay in your history.", comment: ""),
                     actionTitle: NSLocalizedString("Delete List", comment: ""))
        { [weak self] in
            self?.select(collection: .history)

            DatabaseManager.shared.persistentContainer.viewContext.delete(list)
            self?.saveChanges()
            Haptics.warning()
        }
    }

    func confirm(title: String, message: String, actionTitle: String, handler: @escaping () -> Void)
    {
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alertController.addAction(.cancel)
        alertController.addAction(UIAlertAction(title: actionTitle, style: .destructive) { _ in handler() })
        self.present(alertController, animated: true)
    }

    @objc func showSettings(_ sender: UIBarButtonItem)
    {
        let settingsViewController = SettingsViewController()
        settingsViewController.onShowSetupGuide = { [weak self] in
            self?.dismiss(animated: true) {
                self?.presentOnboarding()
            }
        }

        // A sheet on iPhone; a popover from the button on iPad.
        settingsViewController.modalPresentationStyle = self.traitCollection.horizontalSizeClass == .regular ? .popover : .pageSheet
        settingsViewController.popoverPresentationController?.sourceItem = sender
        settingsViewController.preferredContentSize = CGSize(width: 400, height: 640)
        settingsViewController.sheetPresentationController?.prefersGrabberVisible = true
        self.present(settingsViewController, animated: true)
    }
}

// MARK: - Item actions

private extension HistoryViewController
{
    func saveChanges()
    {
        let context = DatabaseManager.shared.persistentContainer.viewContext
        guard context.hasChanges else { return }

        do
        {
            try context.save()
        }
        catch
        {
            print("Failed to save view context.", error)

            let alertController = UIAlertController(title: NSLocalizedString("Couldn't Save Changes", comment: ""), message: error.localizedDescription, preferredStyle: .alert)
            alertController.addAction(.ok)
            self.present(alertController, animated: true)
        }
    }

    func copy(_ item: PasteboardItem)
    {
        UIPasteboard.general.copy(item)
        self.confirm(NSLocalizedString("Copied", comment: ""))
    }

    func moveToTrash(_ item: PasteboardItem)
    {
        item.trashedDate = Date()
        self.saveChanges()
        Haptics.impact()
    }

    func restore(_ item: PasteboardItem)
    {
        item.trashedDate = nil
        self.saveChanges()
        self.confirm(NSLocalizedString("Restored", comment: ""), systemImage: "arrow.uturn.backward.circle.fill")
    }

    func deletePermanently(_ items: [PasteboardItem])
    {
        // Marked items are removed by purge(), which runs the same deletion as the history limit.
        items.forEach { $0.isMarkedForDeletion = true }
        self.saveChanges()
        DatabaseManager.shared.purge()
        Haptics.warning()
    }

    func toggleFavorite(_ item: PasteboardItem)
    {
        item.isFavorite.toggle()
        self.saveChanges()
        Haptics.selection()
    }

    func togglePin(_ item: PasteboardItem)
    {
        item.isPinned.toggle()
        self.saveChanges()
        Haptics.selection()
    }

    func toggleMembership(of item: PasteboardItem, in list: ClippingList)
    {
        if item.lists.contains(list)
        {
            item.mutableSetValue(forKey: "lists").remove(list)
        }
        else
        {
            item.mutableSetValue(forKey: "lists").add(list)
        }

        self.saveChanges()
        Haptics.selection()
    }

    func makeAddToListMenu(for item: PasteboardItem) -> UIMenu
    {
        var actions: [UIMenuElement] = self.fetchLists().map { list in
            UIAction(title: list.name, state: item.lists.contains(list) ? .on : .off) { [weak self] _ in
                self?.toggleMembership(of: item, in: list)
            }
        }

        actions.append(UIAction(title: NSLocalizedString("New List…", comment: ""), image: UIImage(systemName: "plus")) { [weak self] _ in
            self?.presentNewList(adding: item)
        })

        return UIMenu(title: NSLocalizedString("Add to List", comment: ""), image: UIImage(systemName: "text.badge.plus"), children: actions)
    }

    func makeMenuElements(for item: PasteboardItem, sourceView: UIView?) -> [UIMenuElement]
    {
        if self.collection == .trash
        {
            return [
                UIAction(title: NSLocalizedString("Restore", comment: ""), image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
                    self?.restore(item)
                },
                UIAction(title: NSLocalizedString("Copy", comment: ""), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                    self?.copy(item)
                },
                UIAction(title: NSLocalizedString("Delete Permanently", comment: ""), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.deletePermanently([item])
                }
            ]
        }

        var copyActions: [UIMenuElement] = [
            UIAction(title: NSLocalizedString("Copy", comment: ""), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copy(item)
            }
        ]

        if let copyAsMenu = item.makeCopyAsMenu(onCopy: { [weak self] in self?.confirm() })
        {
            copyActions.append(copyAsMenu)
        }

        copyActions.append(UIAction(title: NSLocalizedString("Share…", comment: ""), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            self?.share(item, from: sourceView)
        })

        let favoriteAction = UIAction(title: item.isFavorite ? NSLocalizedString("Remove from Favorites", comment: "") : NSLocalizedString("Add to Favorites", comment: ""),
                                      image: UIImage(systemName: item.isFavorite ? "star.slash" : "star")) { [weak self] _ in
            self?.toggleFavorite(item)
        }

        let pinAction = UIAction(title: item.isPinned ? NSLocalizedString("Unpin", comment: "") : NSLocalizedString("Pin to Top", comment: ""),
                                 image: UIImage(systemName: item.isPinned ? "pin.slash" : "pin")) { [weak self] _ in
            self?.togglePin(item)
        }

        var organizeActions: [UIMenuElement] = [favoriteAction, pinAction, self.makeAddToListMenu(for: item)]

        if let list = self.currentList()
        {
            organizeActions.append(UIAction(title: String(format: NSLocalizedString("Remove from “%@”", comment: ""), list.name), image: UIImage(systemName: "minus.circle")) { [weak self] _ in
                item.mutableSetValue(forKey: "lists").remove(list)
                self?.saveChanges()
            })
        }

        if let location = item.location
        {
            organizeActions.append(UIAction(title: NSLocalizedString("Show Location", comment: ""), image: UIImage(systemName: "location")) { [weak self] _ in
                self?.showLocation(location)
            })
        }

        let trashAction = UIAction(title: NSLocalizedString("Move to Trash", comment: ""), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.moveToTrash(item)
        }

        return [
            UIMenu(options: .displayInline, children: copyActions),
            UIMenu(options: .displayInline, children: organizeActions),
            trashAction
        ]
    }

    func accessibilityActions(for item: PasteboardItem) -> [UIAccessibilityCustomAction]
    {
        if self.collection == .trash
        {
            return [
                UIAccessibilityCustomAction(name: NSLocalizedString("Restore", comment: ""), image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
                    self?.restore(item)
                    return true
                },
                UIAccessibilityCustomAction(name: NSLocalizedString("Delete Permanently", comment: ""), image: UIImage(systemName: "trash")) { [weak self] _ in
                    self?.deletePermanently([item])
                    return true
                }
            ]
        }

        return [
            UIAccessibilityCustomAction(name: NSLocalizedString("Copy", comment: ""), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copy(item)
                return true
            },
            UIAccessibilityCustomAction(name: item.isFavorite ? NSLocalizedString("Remove from Favorites", comment: "") : NSLocalizedString("Add to Favorites", comment: ""), image: UIImage(systemName: "star")) { [weak self] _ in
                self?.toggleFavorite(item)
                return true
            },
            UIAccessibilityCustomAction(name: item.isPinned ? NSLocalizedString("Unpin", comment: "") : NSLocalizedString("Pin to Top", comment: ""), image: UIImage(systemName: "pin")) { [weak self] _ in
                self?.togglePin(item)
                return true
            },
            UIAccessibilityCustomAction(name: NSLocalizedString("Move to Trash", comment: ""), image: UIImage(systemName: "trash")) { [weak self] _ in
                self?.moveToTrash(item)
                return true
            }
        ]
    }

    func leadingSwipeActions(for indexPath: IndexPath) -> UISwipeActionsConfiguration?
    {
        guard self.collection != .trash, let item = self.item(at: indexPath) else { return nil }

        let copyAction = UIContextualAction(style: .normal, title: NSLocalizedString("Copy", comment: "")) { [weak self] _, _, completion in
            self?.copy(item)
            completion(true)
        }
        copyAction.image = UIImage(systemName: "doc.on.doc")
        copyAction.backgroundColor = .systemBlue

        let configuration = UISwipeActionsConfiguration(actions: [copyAction])
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }

    func trailingSwipeActions(for indexPath: IndexPath) -> UISwipeActionsConfiguration?
    {
        guard let item = self.item(at: indexPath) else { return nil }

        if self.collection == .trash
        {
            let restoreAction = UIContextualAction(style: .normal, title: NSLocalizedString("Restore", comment: "")) { [weak self] _, _, completion in
                self?.restore(item)
                completion(true)
            }
            restoreAction.image = UIImage(systemName: "arrow.uturn.backward")
            restoreAction.backgroundColor = .systemGreen

            let deleteAction = UIContextualAction(style: .destructive, title: NSLocalizedString("Delete", comment: "")) { [weak self] _, _, completion in
                self?.deletePermanently([item])
                completion(true)
            }
            deleteAction.image = UIImage(systemName: "trash")

            return UISwipeActionsConfiguration(actions: [deleteAction, restoreAction])
        }

        let trashAction = UIContextualAction(style: .destructive, title: NSLocalizedString("Trash", comment: "")) { [weak self] _, _, completion in
            self?.moveToTrash(item)
            completion(true)
        }
        trashAction.image = UIImage(systemName: "trash")

        let pinAction = UIContextualAction(style: .normal, title: item.isPinned ? NSLocalizedString("Unpin", comment: "") : NSLocalizedString("Pin", comment: "")) { [weak self] _, _, completion in
            self?.togglePin(item)
            completion(true)
        }
        pinAction.image = UIImage(systemName: item.isPinned ? "pin.slash.fill" : "pin.fill")
        pinAction.backgroundColor = .systemOrange

        let favoriteAction = UIContextualAction(style: .normal, title: item.isFavorite ? NSLocalizedString("Unfavorite", comment: "") : NSLocalizedString("Favorite", comment: "")) { [weak self] _, _, completion in
            self?.toggleFavorite(item)
            completion(true)
        }
        favoriteAction.image = UIImage(systemName: item.isFavorite ? "star.slash.fill" : "star.fill")
        favoriteAction.backgroundColor = .systemYellow

        return UISwipeActionsConfiguration(actions: [trashAction, pinAction, favoriteAction])
    }

    @objc func emptyTrashTapped(_ sender: UIBarButtonItem)
    {
        let items = self.fetchedResultsController.fetchedObjects ?? []
        guard !items.isEmpty else { return }

        let alertController = UIAlertController(title: NSLocalizedString("Empty Trash?", comment: ""),
                                                message: String.localizedStringWithFormat(NSLocalizedString(items.count == 1 ? "%d clipping will be deleted permanently. You can't undo this." : "%d clippings will be deleted permanently. You can't undo this.", comment: ""), items.count),
                                                preferredStyle: .actionSheet)
        alertController.addAction(.cancel)
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Empty Trash", comment: ""), style: .destructive) { [weak self] _ in
            self?.deletePermanently(items)
        })
        alertController.popoverPresentationController?.sourceItem = sender
        self.present(alertController, animated: true)
    }

    @objc func didEnterBackground(_ notification: Notification)
    {
        // Save any pending changes to disk.
        self.saveChanges()

        self.undoManager?.removeAllActions()

        self.stopUpdating()
    }

    @objc func willEnterForeground(_ notification: Notification)
    {
        self.startUpdating()
        self.reconfigureVisibleItems()
    }

    @objc func settingsDidChange(_ notification: Notification)
    {
        self.applySnapshot(animated: false)
    }

    @IBAction func unwindToHistoryViewController(_ segue: UIStoryboardSegue)
    {
    }
}

// MARK: - UICollectionViewDelegate

extension HistoryViewController: UICollectionViewDelegate
{
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath)
    {
        collectionView.deselectItem(at: indexPath, animated: true)

        guard let item = self.item(at: indexPath) else { return }

        let detailViewController = ClippingDetailViewController(pasteboardItem: item)
        self.navigationController?.pushViewController(detailViewController, animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration?
    {
        guard indexPaths.count == 1, let indexPath = indexPaths.first, let item = self.item(at: indexPath) else { return nil }

        let sourceView = collectionView.cellForItem(at: indexPath)

        return UIContextMenuConfiguration(identifier: item.objectID, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: self.makeMenuElements(for: item, sourceView: sourceView))
        }
    }
}

extension HistoryViewController: NSFetchedResultsControllerDelegate
{
    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>)
    {
        self.applySnapshot(animated: true)

        if self.collection == .trash
        {
            self.updateNavigationItems()
        }
    }
}

extension HistoryViewController: UISearchResultsUpdating
{
    func updateSearchResults(for searchController: UISearchController)
    {
        self.searchText = searchController.searchBar.text
        self.applySnapshot(animated: false)
    }
}

private extension HistoryViewController
{
    func presentOnboardingIfNeeded()
    {
        guard !UserDefaults.shared.hasCompletedOnboarding, self.presentedViewController == nil else { return }
        self.presentOnboarding()
    }

    func presentOnboarding()
    {
        let onboardingViewController = OnboardingViewController()
        onboardingViewController.isModalInPresentation = !UserDefaults.shared.hasCompletedOnboarding
        onboardingViewController.onFinish = { [weak self] in
            UserDefaults.shared.hasCompletedOnboarding = true
            self?.dismiss(animated: true)
        }

        self.present(onboardingViewController, animated: true)
    }
}

#if DEBUG
// MARK: - Demo screens

private extension HistoryViewController
{
    /// Opens the screen named by the -ClipboardDemoScreen launch argument, for simulator screenshots.
    /// Values: grid, grid-favorites, favorites, trash, list, filter-code, search, detail-text, detail-image,
    /// detail-link, detail-code, settings, map, keyboard.
    func showDemoScreenIfRequested()
    {
        guard let screen = UserDefaults.standard.string(forKey: "ClipboardDemoScreen"), !self.hasShownDemoScreen else { return }
        self.hasShownDemoScreen = true

        // Give the seeded clippings a moment to arrive from the background context.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Every run starts from the list, whatever layout the last run left behind.
            if !screen.hasPrefix("grid") { self.setLayoutMode(.list) }
            self.showDemoScreen(screen)
        }
    }

    var hasShownDemoScreen: Bool {
        get { objc_getAssociatedObject(self, &demoScreenKey) as? Bool ?? false }
        set { objc_setAssociatedObject(self, &demoScreenKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    func showDemoScreen(_ screen: String)
    {
        let items = self.fetchedResultsController.fetchedObjects ?? []

        func showDetail(where predicate: (PasteboardItem) -> Bool)
        {
            guard let item = items.first(where: predicate) else { return }
            self.navigationController?.pushViewController(ClippingDetailViewController(pasteboardItem: item), animated: false)
        }

        switch screen
        {
        case "favorites": self.select(collection: .favorites)
        case "trash": self.select(collection: .trash)
        case "list":
            if let list = self.fetchLists().first(where: { $0.name == "Snippets" }) { self.select(collection: .list(list.objectID)) }
        case "filter-code": self.setContentFilter(.code)
        case "grid": self.setLayoutMode(.grid)
        case "grid-favorites":
            self.setLayoutMode(.grid)
            self.select(collection: .favorites)
        case "search":
            self.navigationItem.searchController?.isActive = true
            self.navigationItem.searchController?.searchBar.text = "brown"
        case "detail-text": showDetail { $0.contentText?.hasPrefix("Here's") == true }
        case "detail-image": showDetail { $0.preferredRepresentation?.type == .image }
        case "detail-link": showDetail { $0.linkURL != nil }
        case "detail-code": showDetail { $0.contentText?.hasPrefix("func") == true }
        case "map": self.tabBarController?.selectedIndex = 1
        case "settings": self.showSettings(self.navigationItem.rightBarButtonItems![0])
        case "keyboard":
            let keyboard = Keyboard(inputViewController: nil, needsInputModeSwitchKey: true)
                .environment(\.managedObjectContext, DatabaseManager.shared.persistentContainer.viewContext)
            let hostingController = UIHostingController(rootView: keyboard)
            hostingController.sheetPresentationController?.detents = [.medium()]
            self.present(hostingController, animated: false)
        default: break
        }
    }
}

private var demoScreenKey = 0
#endif
