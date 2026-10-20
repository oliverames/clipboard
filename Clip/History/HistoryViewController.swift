//
//  HistoryViewController.swift
//  Clip
//
//  Created by Riley Testut on 6/10/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import UIKit
import Combine
import CoreData
import CoreLocation
import Contacts

import ClipKit
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
        case .all: return NSLocalizedString("All Types", comment: "")
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
}

class HistoryViewController: UITableViewController
{
    private var dataSource: UITableViewDiffableDataSource<Int, NSManagedObjectID>!
    private var fetchedResultsController: NSFetchedResultsController<PasteboardItem>!

    private var collection = HistoryCollection.history
    private var contentFilter = ContentFilter.all
    private var searchText: String?
    private var matches = [NSManagedObjectID: FuzzyMatch]()

    private let thumbnailCache = NSCache<NSManagedObjectID, UIImage>()
    private var pendingThumbnails = Set<NSManagedObjectID>()

    private var settingsBarButtonItem: UIBarButtonItem?
    private var defaultTitle: String?
    private lazy var placeholderView: RSTPlaceholderView = RSTPlaceholderView()

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
        self.settingsBarButtonItem = self.navigationItem.rightBarButtonItem

        self.tableView.rowHeight = UITableView.automaticDimension
        self.tableView.estimatedRowHeight = 72

        // Align separators with the clipping text, not the icon.
        self.tableView.separatorInset = UIEdgeInsets(top: 0, left: 72, bottom: 0, right: 0)

        let searchController = UISearchController(searchResultsController: nil)
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchResultsUpdater = self
        searchController.searchBar.placeholder = NSLocalizedString("Search Clippings", comment: "")
        self.navigationItem.searchController = searchController
        self.definesPresentationContext = true

        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: RSTCellContentGenericCellIdentifier)
        self.dataSource = self.makeDataSource()
        self.updateFetchedResultsController()

        DatabaseManager.shared.persistentContainer.viewContext.undoManager = self.undoManager

        NotificationCenter.default.addObserver(self, selector: #selector(HistoryViewController.didEnterBackground(_:)), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(HistoryViewController.willEnterForeground(_:)), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(HistoryViewController.settingsDidChange(_:)), name: SettingsViewController.settingsDidChangeNotification, object: nil)

        self.fetchLimitSettingObservation = UserDefaults.shared.observe(\.historyLimit) { [weak self] (defaults, change) in
            self?.applySnapshot(animated: true)
        }

        LinkPreviewStore.shared.$previews
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reconfigureVisibleRows() }
            .store(in: &self.cancellables)

        if let tabBar = self.navigationController?.tabBarController?.tabBar
        {
            let appearance = tabBar.standardAppearance
            tabBar.scrollEdgeAppearance = appearance
        }

        self.navigationController?.tabBarItem.image = UIImage(systemName: "list.bullet")

        self.startUpdating()
    }

    override func viewDidLayoutSubviews()
    {
        super.viewDidLayoutSubviews()

        // The outer display reserves its trailing edge for the status bar and toolbar, so rows stop short of it.
        let trailingRegionWidth = self.tableView.reservedRegions(kind: .occlusion, options: []).reduce(0.0) { (width, region) in
            guard region.isActive, region.frame.maxX >= self.tableView.bounds.maxX - 1 else { return width }
            return max(width, self.tableView.bounds.maxX - region.frame.minX)
        }

        let trailingInset = trailingRegionWidth > 0 ? trailingRegionWidth + 8 : 0
        guard self.tableView.contentInset.right != trailingInset else { return }

        self.tableView.contentInset.right = trailingInset
        self.tableView.verticalScrollIndicatorInsets.right = trailingInset
    }

    override func viewDidAppear(_ animated: Bool)
    {
        super.viewDidAppear(animated)

        self.becomeFirstResponder()
        self.presentOnboardingIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool)
    {
        super.viewWillDisappear(animated)

        self.resignFirstResponder()
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?)
    {
        guard segue.identifier == "showSettings" else { return }
        guard let sender = sender as? UIBarButtonItem else { return }

        let navigationController = segue.destination as! UINavigationController

        let settingsViewController = navigationController.viewControllers[0] as! SettingsViewController
        settingsViewController.view.layoutIfNeeded()

        navigationController.preferredContentSize = CGSize(width: 375, height: settingsViewController.tableView.contentSize.height)

        navigationController.popoverPresentationController?.delegate = self
        navigationController.popoverPresentationController?.barButtonItem = sender
    }
}

private extension HistoryViewController
{
    func subscribe()
    {
        //TODO: Uncomment once we can tell user to enable location for background execution.
        //ApplicationMonitor.shared.locationManager.$status
        //    .receive(on: RunLoop.main)
        //    .compactMap { $0?.error }
        //    .sink { self.present($0) }
        //    .store(in: &self.cancellables)
    }

    func makeDataSource() -> UITableViewDiffableDataSource<Int, NSManagedObjectID>
    {
        let dataSource = UITableViewDiffableDataSource<Int, NSManagedObjectID>(tableView: self.tableView) { [weak self] (tableView, indexPath, objectID) -> UITableViewCell? in
            let cell = tableView.dequeueReusableCell(withIdentifier: RSTCellContentGenericCellIdentifier, for: indexPath)

            if let self = self, let item = self.item(withObjectID: objectID)
            {
                self.configure(cell, with: item)
            }

            return cell
        }

        return dataSource
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

        items = items.filter { self.matchesContentFilter($0) }

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

    func matchesContentFilter(_ item: PasteboardItem) -> Bool
    {
        switch self.contentFilter
        {
        case .all: return true
        case .text: return item.preferredRepresentation?.type == .text
        case .richText: return item.preferredRepresentation?.type == .attributedText
        case .image: return item.preferredRepresentation?.type == .image
        case .link: return item.linkURL != nil
        case .code: return self.codeLanguage(for: item) != nil
        }
    }

    /// The text a row shows before any link preview arrives, which is also what search matches.
    func displayText(for item: PasteboardItem) -> String?
    {
        return item.linkURL?.absoluteString ?? item.contentText
    }

    func codeLanguage(for item: PasteboardItem) -> CodeLanguage?
    {
        guard let type = item.preferredRepresentation?.type, type == .text || type == .attributedText else { return nil }
        guard let text = item.contentText else { return nil }

        // Detection only needs the start of a clipping, and long clippings shouldn't stall scrolling.
        return CodeDetector.detect(String(text.prefix(4_000)))
    }

    func applySnapshot(animated: Bool)
    {
        let items = self.visibleItems()
        let objectIDs = items.map { $0.objectID }

        var snapshot = NSDiffableDataSourceSnapshot<Int, NSManagedObjectID>()
        snapshot.appendSections([0])
        snapshot.appendItems(objectIDs)

        // Rows keep their identity when their contents change, so reconfigure the ones that already exist.
        let existingObjectIDs = Set(self.dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(objectIDs.filter { existingObjectIDs.contains($0) })

        self.dataSource.apply(snapshot, animatingDifferences: animated)
        self.updatePlaceholder(isEmpty: objectIDs.isEmpty)
    }

    func updatePlaceholder(isEmpty: Bool)
    {
        guard isEmpty else
        {
            self.tableView.backgroundView = nil
            return
        }

        let text: (title: String, detail: String)

        if let searchText, !searchText.isEmpty
        {
            text = (NSLocalizedString("No Results", comment: ""), NSLocalizedString("Try a different search or filter.", comment: ""))
        }
        else
        {
            switch self.collection
            {
            case .history: text = (NSLocalizedString("No Clippings", comment: ""), NSLocalizedString("Items that you've copied to the clipboard will appear here.", comment: ""))
            case .favorites: text = (NSLocalizedString("No Favorites", comment: ""), NSLocalizedString("Star a clipping to keep it here.", comment: ""))
            case .trash: text = (NSLocalizedString("Trash Is Empty", comment: ""), NSLocalizedString("Clippings you delete appear here until you empty the Trash.", comment: ""))
            case .list: text = (NSLocalizedString("Empty List", comment: ""), NSLocalizedString("Add clippings to this list from their context menus.", comment: ""))
            }
        }

        self.placeholderView.textLabel.text = text.title
        self.placeholderView.detailTextLabel.text = text.detail
        self.tableView.backgroundView = self.placeholderView
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

    func reconfigureItem(_ objectID: NSManagedObjectID)
    {
        var snapshot = self.dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(objectID) else { return }

        snapshot.reconfigureItems([objectID])
        self.dataSource.apply(snapshot, animatingDifferences: false)
    }

    func configure(_ cell: UITableViewCell, with item: PasteboardItem)
    {
        var configuration = UIListContentConfiguration.subtitleCell()
        configuration.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        configuration.imageToTextPadding = 12
        configuration.imageProperties.reservedLayoutSize = CGSize(width: 40, height: 40)
        configuration.imageProperties.maximumSize = CGSize(width: 40, height: 40)
        configuration.imageProperties.cornerRadius = 8
        configuration.imageProperties.tintColor = .secondaryLabel
        configuration.textProperties.numberOfLines = 2
        configuration.secondaryTextProperties.color = .secondaryLabel
        configuration.secondaryText = self.secondaryText(for: item)

        let match = self.matches[item.objectID]

        if let link = item.linkURL
        {
            LinkPreviewStore.shared.fetchPreviewIfNeeded(for: link)
            let preview = LinkPreviewStore.shared.preview(for: link)

            if let title = preview?.title
            {
                configuration.textProperties.numberOfLines = 2
                configuration.text = title
            }
            else
            {
                // Raw addresses keep a single line so the middle of the address stays visible.
                configuration.textProperties.numberOfLines = 1
                configuration.textProperties.lineBreakMode = .byTruncatingMiddle
                self.setText(link.absoluteString, match: match, in: &configuration)
            }

            configuration.image = preview?.icon ?? UIImage(systemName: "link")
        }
        else if let representation = item.preferredRepresentation
        {
            self.setText(item.contentText ?? representation.type.localizedName, match: match, in: &configuration)

            if representation.type == .image, let thumbnail = self.thumbnail(for: item)
            {
                configuration.image = thumbnail
            }
            else
            {
                configuration.image = UIImage(systemName: representation.type.symbolName)
            }
        }
        else
        {
            configuration.text = NSLocalizedString("Unknown", comment: "")
        }

        cell.contentConfiguration = configuration
        cell.accessoryView = self.makeAccessoryView(for: item)
    }

    func setText(_ text: String, match: FuzzyMatch?, in configuration: inout UIListContentConfiguration)
    {
        if let match, !match.ranges.isEmpty
        {
            configuration.attributedText = self.attributedText(for: text, match: match)
        }
        else
        {
            configuration.text = text
        }
    }

    /// Bolds the characters a search matched, the way Spotlight and Mail mark search hits.
    func attributedText(for text: String, match: FuzzyMatch) -> NSAttributedString
    {
        let attributedText = NSMutableAttributedString(string: text)
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))

        for range in match.ranges
        {
            attributedText.addAttribute(.font, value: font, range: NSRange(range, in: text))
        }

        return attributedText
    }

    /// Returns a cached thumbnail, or decodes one in the background and reconfigures the row when it's ready.
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
            let image = UIImage(data: data)?.resizing(toFill: CGSize(width: 500, height: 500))

            DispatchQueue.main.async {
                self.pendingThumbnails.remove(objectID)

                guard let image else { return }

                self.thumbnailCache.setObject(image, forKey: objectID)
                self.reconfigureItem(objectID)
            }
        }

        return nil
    }

    func makeAccessoryView(for item: PasteboardItem) -> UIView
    {
        var accessoryViews = [UIView]()

        if item.isPinned
        {
            accessoryViews.append(self.makeSymbolView(systemImageName: "pin.fill", tintColor: .secondaryLabel))
        }

        if item.isFavorite
        {
            accessoryViews.append(self.makeSymbolView(systemImageName: "star.fill", tintColor: .systemYellow))
        }

        if UserDefaults.shared.showLocationIcon, item.location != nil
        {
            let locationButton = self.makeAccessoryButton(systemImageName: "location")
            locationButton.addTarget(self, action: #selector(HistoryViewController.locationButtonTapped(_:)), for: .primaryActionTriggered)
            accessoryViews.append(locationButton)
        }

        if let badge = self.makeBadgeView(for: item)
        {
            accessoryViews.append(badge)
        }

        let stackView = UIStackView(arrangedSubviews: accessoryViews)
        stackView.spacing = 8
        stackView.alignment = .center
        stackView.frame.size = stackView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return stackView
    }

    func makeSymbolView(systemImageName: String, tintColor: UIColor) -> UIView
    {
        let imageView = UIImageView(image: UIImage(systemName: systemImageName))
        imageView.tintColor = tintColor
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
        return imageView
    }

    func makeAccessoryButton(systemImageName: String) -> UIButton
    {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: systemImageName)
        configuration.baseForegroundColor = .secondaryLabel

        return UIButton(configuration: configuration, primaryAction: nil)
    }

    /// A small pill naming the clipping's type: HTTP, TXT, IMG, or the language of a code clipping.
    func makeBadgeView(for item: PasteboardItem) -> UIView?
    {
        let title: String

        switch item.preferredRepresentation?.type
        {
        case nil: return nil
        case .image?: title = "IMG"
        case .text?, .attributedText?, .url?:
            if item.linkURL != nil
            {
                title = "HTTP"
            }
            else if let language = self.codeLanguage(for: item)
            {
                title = language.displayName
            }
            else
            {
                title = "TXT"
            }
        }

        let label = UILabel()
        label.text = title
        label.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .systemFont(ofSize: 11, weight: .bold))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false

        let badge = UIView()
        badge.backgroundColor = .tertiarySystemFill
        badge.layer.cornerRadius = 8
        badge.layer.masksToBounds = true
        badge.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: badge.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -3)
        ])

        return badge
    }

    func secondaryText(for item: PasteboardItem) -> String
    {
        // The badge names the type, so the subtitle carries the source for links and the age for everything else.
        if let link = item.linkURL
        {
            return (link.host ?? link.absoluteString) + " · " + item.ageText()
        }

        return item.ageText()
    }

    func updateDate(for cell: UITableViewCell, item: PasteboardItem)
    {
        guard var configuration = cell.contentConfiguration as? UIListContentConfiguration else { return }

        let secondaryText = self.secondaryText(for: item)
        guard configuration.secondaryText != secondaryText else { return }

        configuration.secondaryText = secondaryText
        cell.contentConfiguration = configuration
    }

    func reconfigureVisibleRows()
    {
        // The diffable data source owns the table, so rows must be reconfigured through its snapshot.
        let objectIDs = (self.tableView.indexPathsForVisibleRows ?? []).compactMap { self.dataSource.itemIdentifier(for: $0) }
        guard !objectIDs.isEmpty else { return }

        var snapshot = self.dataSource.snapshot()
        snapshot.reconfigureItems(objectIDs)
        self.dataSource.apply(snapshot, animatingDifferences: false)
    }

    func indexPath(for control: UIControl) -> IndexPath?
    {
        let point = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: self.tableView)
        return self.tableView.indexPathForRow(at: point)
    }

    func share(_ item: PasteboardItem, at indexPath: IndexPath)
    {
        let activityViewController = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        activityViewController.popoverPresentationController?.sourceView = self.tableView
        activityViewController.popoverPresentationController?.sourceRect = self.tableView.rectForRow(at: indexPath)
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

                    message = nil
                }
                else if let error
                {
                    title = NSLocalizedString("Unable to Look Up Location", comment: "")
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

        self.updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] (timer) in
            guard let self = self else { return }

            for indexPath in self.tableView.indexPathsForVisibleRows ?? []
            {
                guard let cell = self.tableView.cellForRow(at: indexPath), let item = self.item(at: indexPath) else { continue }
                self.updateDate(for: cell, item: item)
            }
        }
    }

    func stopUpdating()
    {
        self.updateTimer?.invalidate()
        self.updateTimer = nil
    }
}

private extension HistoryViewController
{
    func present(_ error: Error)
    {
        let nsError = error as NSError

        let alertController = UIAlertController(title: nsError.localizedFailureReason ?? nsError.localizedDescription,
                                                message: nsError.localizedRecoverySuggestion, preferredStyle: .alert)

        if let recoverableError = error as? RecoverableError, !recoverableError.recoveryOptions.isEmpty
        {
            alertController.addAction(.cancel)

            for (index, title) in zip(0..., recoverableError.recoveryOptions)
            {
                let action = UIAlertAction(title: title, style: .default) { (action) in
                    recoverableError.attemptRecovery(optionIndex: index) { (success) in
                        print("Recovered from error with success:", success)
                    }
                }
                alertController.addAction(action)
            }
        }
        else
        {
            alertController.addAction(.ok)
        }

        self.present(alertController, animated: true, completion: nil)
    }
}

// MARK: - Navigation

private extension HistoryViewController
{
    func updateNavigationItems()
    {
        let filterButton = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal.decrease.circle"), menu: self.makeFilterMenu())
        filterButton.accessibilityLabel = NSLocalizedString("Filter", comment: "")

        self.navigationItem.rightBarButtonItems = [self.settingsBarButtonItem, filterButton].compactMap { $0 }

        switch self.collection
        {
        case .history, .favorites:
            self.navigationItem.leftBarButtonItem = nil

        case .trash:
            let emptyButton = UIBarButtonItem(title: NSLocalizedString("Empty", comment: ""), style: .plain, target: self, action: #selector(HistoryViewController.emptyTrashTapped(_:)))
            self.navigationItem.leftBarButtonItem = emptyButton

        case .list:
            let listMenu = UIMenu(children: [
                UIAction(title: NSLocalizedString("Rename List…", comment: ""), image: UIImage(systemName: "pencil")) { [weak self] _ in
                    self?.renameCurrentList()
                },
                UIAction(title: NSLocalizedString("Delete List…", comment: ""), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.deleteCurrentList()
                }
            ])

            self.navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: listMenu)
        }
    }

    func makeFilterMenu() -> UIMenu
    {
        let collections: [(collection: HistoryCollection, title: String, symbolName: String)] = [
            (.history, NSLocalizedString("All Clippings", comment: ""), "list.bullet"),
            (.favorites, NSLocalizedString("Favorites", comment: ""), "star"),
            (.trash, NSLocalizedString("Trash", comment: ""), "trash")
        ]

        let collectionActions: [UIMenuElement] = collections.map { (collection, title, symbolName) in
            UIAction(title: title, image: UIImage(systemName: symbolName), state: self.collection == collection ? .on : .off) { [weak self] _ in
                self?.select(collection: collection)
            }
        }

        let typeActions: [UIMenuElement] = ContentFilter.allCases.map { filter in
            UIAction(title: filter.title, image: UIImage(systemName: filter.symbolName), state: self.contentFilter == filter ? .on : .off) { [weak self] _ in
                self?.contentFilter = filter
                self?.applySnapshot(animated: true)
                self?.updateNavigationItems()
            }
        }

        let listsMenu = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self = self else { return completion([]) }

            var listActions: [UIMenuElement] = self.fetchLists().map { list in
                UIAction(title: list.name, state: self.collection == .list(list.objectID) ? .on : .off) { [weak self] _ in
                    self?.select(collection: .list(list.objectID))
                }
            }

            listActions.append(UIAction(title: NSLocalizedString("New List…", comment: ""), image: UIImage(systemName: "plus")) { [weak self] _ in
                self?.presentNewList(adding: nil)
            })

            completion([UIMenu(title: NSLocalizedString("Lists", comment: ""), options: .displayInline, children: listActions)])
        }

        return UIMenu(children: [
            UIMenu(options: .displayInline, children: collectionActions),
            UIMenu(title: NSLocalizedString("Type", comment: ""), options: .displayInline, children: typeActions),
            listsMenu
        ])
    }

    func select(collection: HistoryCollection)
    {
        self.collection = collection
        self.navigationItem.title = self.title(for: collection)
        self.updateFetchedResultsController()
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
            textField.autocapitalizationType = .sentences
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
        })

        self.present(alertController, animated: true)
    }

    func renameCurrentList()
    {
        guard let list = self.currentList() else { return }

        let alertController = UIAlertController(title: NSLocalizedString("Rename List", comment: ""), message: nil, preferredStyle: .alert)
        alertController.addTextField { (textField) in
            textField.text = list.name
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

        self.confirm(title: NSLocalizedString("Delete List?", comment: ""),
                     message: NSLocalizedString("The clippings in this list stay in your history.", comment: ""),
                     actionTitle: NSLocalizedString("Delete", comment: ""))
        { [weak self] in
            self?.select(collection: .history)

            DatabaseManager.shared.persistentContainer.viewContext.delete(list)
            self?.saveChanges()
        }
    }

    func confirm(title: String, message: String, actionTitle: String, handler: @escaping () -> Void)
    {
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alertController.addAction(.cancel)
        alertController.addAction(UIAlertAction(title: actionTitle, style: .destructive) { _ in handler() })
        self.present(alertController, animated: true)
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
        }
    }

    func moveToTrash(_ item: PasteboardItem)
    {
        item.trashedDate = Date()
        self.saveChanges()
    }

    func restore(_ item: PasteboardItem)
    {
        item.trashedDate = nil
        self.saveChanges()
    }

    func deletePermanently(_ items: [PasteboardItem])
    {
        // Marked items are removed by purge(), which runs the same deletion as the history limit.
        items.forEach { $0.isMarkedForDeletion = true }
        self.saveChanges()
        DatabaseManager.shared.purge()
    }

    func toggleFavorite(_ item: PasteboardItem)
    {
        item.isFavorite.toggle()
        self.saveChanges()
    }

    func togglePin(_ item: PasteboardItem)
    {
        item.isPinned.toggle()
        self.saveChanges()
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

    func makeMenuElements(for item: PasteboardItem) -> [UIMenuElement]
    {
        var elements = [UIMenuElement]()

        if self.collection == .trash
        {
            elements.append(UIAction(title: NSLocalizedString("Restore", comment: ""), image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
                self?.restore(item)
            })
        }

        elements.append(UIAction(title: NSLocalizedString("Copy", comment: ""), image: UIImage(systemName: "doc.on.doc")) { _ in
            UIPasteboard.general.copy(item)
        })

        if let copyAsMenu = item.makeCopyAsMenu()
        {
            elements.append(copyAsMenu)
        }

        elements.append(UIAction(title: NSLocalizedString("Share", comment: ""), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            guard let self = self, let indexPath = self.indexPath(for: item) else { return }
            self.share(item, at: indexPath)
        })

        if let location = item.location
        {
            elements.append(UIAction(title: NSLocalizedString("Show Location", comment: ""), image: UIImage(systemName: "location")) { [weak self] _ in
                self?.showLocation(location)
            })
        }

        let favoriteAction = UIAction(title: item.isFavorite ? NSLocalizedString("Remove from Favorites", comment: "") : NSLocalizedString("Add to Favorites", comment: ""),
                                      image: UIImage(systemName: item.isFavorite ? "star.slash" : "star")) { [weak self] _ in
            self?.toggleFavorite(item)
        }

        let pinAction = UIAction(title: item.isPinned ? NSLocalizedString("Unpin", comment: "") : NSLocalizedString("Pin to Top", comment: ""),
                                 image: UIImage(systemName: item.isPinned ? "pin.slash" : "pin")) { [weak self] _ in
            self?.togglePin(item)
        }

        elements.append(UIMenu(options: .displayInline, children: [favoriteAction, pinAction]))
        elements.append(self.makeAddToListMenu(for: item))

        if let list = self.currentList()
        {
            elements.append(UIAction(title: NSLocalizedString("Remove from List", comment: ""), image: UIImage(systemName: "minus.circle")) { [weak self] _ in
                item.mutableSetValue(forKey: "lists").remove(list)
                self?.saveChanges()
            })
        }

        if self.collection == .trash
        {
            elements.append(UIAction(title: NSLocalizedString("Delete Permanently", comment: ""), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.deletePermanently([item])
            })
        }
        else
        {
            elements.append(UIAction(title: NSLocalizedString("Move to Trash", comment: ""), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.moveToTrash(item)
            })
        }

        return elements
    }

    func indexPath(for item: PasteboardItem) -> IndexPath?
    {
        guard let objectID = Optional(item.objectID) else { return nil }
        return self.dataSource.indexPath(for: objectID)
    }

    @objc func locationButtonTapped(_ sender: UIButton)
    {
        guard let indexPath = self.indexPath(for: sender), let location = self.item(at: indexPath)?.location else { return }

        self.showLocation(location)
    }

    @objc func emptyTrashTapped(_ sender: UIBarButtonItem)
    {
        let items = self.fetchedResultsController.fetchedObjects ?? []

        self.confirm(title: NSLocalizedString("Empty Trash?", comment: ""),
                     message: NSLocalizedString("Clippings in the Trash are deleted permanently.", comment: ""),
                     actionTitle: NSLocalizedString("Empty Trash", comment: ""))
        { [weak self] in
            self?.deletePermanently(items)
        }
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
    }

    @objc func settingsDidChange(_ notification: Notification)
    {
        self.applySnapshot(animated: false)
    }

    @IBAction func unwindToHistoryViewController(_ segue: UIStoryboardSegue)
    {
    }
}

extension HistoryViewController
{
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath)
    {
        self.tableView.deselectRow(at: indexPath, animated: true)

        guard let item = self.item(at: indexPath) else { return }

        let detailViewController = ClippingDetailViewController(pasteboardItem: item)
        self.navigationController?.pushViewController(detailViewController, animated: true)
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration?
    {
        guard let item = self.item(at: indexPath) else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: self.makeMenuElements(for: item))
        }
    }

    override func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration?
    {
        guard self.collection != .trash, let item = self.item(at: indexPath) else { return nil }

        let copyAction = UIContextualAction(style: .normal, title: NSLocalizedString("Copy", comment: "")) { _, _, completion in
            UIPasteboard.general.copy(item)
            completion(true)
        }
        copyAction.image = UIImage(systemName: "doc.on.doc")

        return UISwipeActionsConfiguration(actions: [copyAction])
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration?
    {
        guard let item = self.item(at: indexPath) else { return nil }

        if self.collection == .trash
        {
            let restoreAction = UIContextualAction(style: .normal, title: NSLocalizedString("Restore", comment: "")) { [weak self] _, _, completion in
                self?.restore(item)
                completion(true)
            }
            restoreAction.image = UIImage(systemName: "arrow.uturn.backward")

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
        pinAction.image = UIImage(systemName: item.isPinned ? "pin.slash" : "pin")
        pinAction.backgroundColor = .systemOrange

        let favoriteAction = UIContextualAction(style: .normal, title: item.isFavorite ? NSLocalizedString("Unfavorite", comment: "") : NSLocalizedString("Favorite", comment: "")) { [weak self] _, _, completion in
            self?.toggleFavorite(item)
            completion(true)
        }
        favoriteAction.image = UIImage(systemName: item.isFavorite ? "star.slash" : "star")
        favoriteAction.backgroundColor = .systemYellow

        return UISwipeActionsConfiguration(actions: [trashAction, pinAction, favoriteAction])
    }
}

extension HistoryViewController: NSFetchedResultsControllerDelegate
{
    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>)
    {
        self.applySnapshot(animated: true)
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

extension HistoryViewController: UIPopoverPresentationControllerDelegate
{
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle
    {
        return .none
    }
}

private extension HistoryViewController
{
    func presentOnboardingIfNeeded()
    {
        guard !UserDefaults.shared.hasCompletedOnboarding, self.presentedViewController == nil else { return }

        let onboardingViewController = OnboardingViewController()
        onboardingViewController.isModalInPresentation = true
        onboardingViewController.onFinish = { [weak self] in
            UserDefaults.shared.hasCompletedOnboarding = true
            self?.dismiss(animated: true)
        }

        self.present(onboardingViewController, animated: true)
    }
}
