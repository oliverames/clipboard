//
//  ClippingDetailViewController.swift
//  Clip
//

import UIKit

import ClipKit

class ClippingDetailViewController: UITableViewController
{
    private enum Section: Int
    {
        case content
        case details
    }

    private let pasteboardItem: PasteboardItem
    private var details = [(title: String, value: String)]()

    init(pasteboardItem: PasteboardItem)
    {
        self.pasteboardItem = pasteboardItem
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder)
    {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad()
    {
        super.viewDidLoad()

        self.title = self.pasteboardItem.preferredRepresentation?.type.localizedName
        self.details = self.makeDetails()

        self.tableView.allowsSelection = false
        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")

        // Actions live in the bottom toolbar, which iOS 27 draws as Liquid Glass.
        var toolbarItems = [
            UIBarButtonItem(image: UIImage(systemName: "doc.on.doc"), style: .plain, target: self, action: #selector(ClippingDetailViewController.copyItem(_:)))
        ]

        if let copyAsMenu = self.pasteboardItem.makeCopyAsMenu()
        {
            toolbarItems.append(UIBarButtonItem.flexibleSpace())
            toolbarItems.append(UIBarButtonItem(image: UIImage(systemName: "textformat.abc"), menu: copyAsMenu))
        }

        toolbarItems.append(UIBarButtonItem.flexibleSpace())
        toolbarItems.append(UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(ClippingDetailViewController.shareItem(_:))))
        self.toolbarItems = toolbarItems
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

    override func numberOfSections(in tableView: UITableView) -> Int
    {
        return 2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int
    {
        switch Section(rawValue: section)
        {
        case .content?: return 1
        case .details?: return self.details.count
        case nil: return 0
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String?
    {
        return (Section(rawValue: section) == .details) ? NSLocalizedString("Details", comment: "") : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell
    {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        cell.contentView.subviews.forEach { $0.removeFromSuperview() }

        switch Section(rawValue: indexPath.section)
        {
        case .content?:
            if let image = self.pasteboardItem.preferredRepresentation?.imageValue
            {
                cell.contentConfiguration = nil
                self.addImageView(image, to: cell)
            }
            else
            {
                var configuration = UIListContentConfiguration.cell()
                configuration.text = self.pasteboardItem.contentText
                configuration.textProperties.numberOfLines = 0
                configuration.textProperties.font = .preferredFont(forTextStyle: .body)
                cell.contentConfiguration = configuration
            }

        case .details?:
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = self.details[indexPath.row].title
            configuration.secondaryText = self.details[indexPath.row].value
            cell.contentConfiguration = configuration

        case nil: break
        }

        return cell
    }
}

private extension ClippingDetailViewController
{
    func makeDetails() -> [(title: String, value: String)]
    {
        let representation = self.pasteboardItem.preferredRepresentation

        var details = [(title: String, value: String)]()
        details.append((NSLocalizedString("Kind", comment: ""), representation?.type.localizedName ?? NSLocalizedString("Unknown", comment: "")))

        if representation?.type != .image, let text = self.pasteboardItem.contentText
        {
            details.append((NSLocalizedString("Characters", comment: ""), "\(text.count)"))
            details.append((NSLocalizedString("Size", comment: ""), ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file)))
        }

        if let image = representation?.imageValue
        {
            details.append((NSLocalizedString("Dimensions", comment: ""), "\(Int(image.size.width * image.scale)) × \(Int(image.size.height * image.scale))"))
        }

        details.append((NSLocalizedString("Date", comment: ""), self.pasteboardItem.date.formatted(date: .abbreviated, time: .shortened)))

        if let host = self.pasteboardItem.linkURL?.host
        {
            details.append((NSLocalizedString("Source", comment: ""), host))
        }

        return details
    }

    func addImageView(_ image: UIImage, to cell: UITableViewCell)
    {
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.layer.cornerRadius = 12
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: image.size.height / image.size.width)
        ])
    }

    @objc func copyItem(_ sender: UIBarButtonItem)
    {
        UIPasteboard.general.copy(self.pasteboardItem)
    }

    @objc func shareItem(_ sender: UIBarButtonItem)
    {
        let activityViewController = UIActivityViewController(activityItems: [self.pasteboardItem], applicationActivities: nil)
        activityViewController.popoverPresentationController?.barButtonItem = sender
        self.present(activityViewController, animated: true)
    }
}
