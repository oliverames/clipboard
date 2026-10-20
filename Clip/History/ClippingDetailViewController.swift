//
//  ClippingDetailViewController.swift
//  Clip
//

import UIKit

import ClipKit

class ClippingDetailViewController: UIViewController
{
    private let pasteboardItem: PasteboardItem

    private let contentMargin: CGFloat = 20

    private weak var scrollView: UIScrollView?
    private var contentLeftConstraint: NSLayoutConstraint?
    private var contentRightConstraint: NSLayoutConstraint?

    init(pasteboardItem: PasteboardItem)
    {
        self.pasteboardItem = pasteboardItem
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder)
    {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad()
    {
        super.viewDidLoad()

        self.view.backgroundColor = .systemBackground
        self.navigationItem.largeTitleDisplayMode = .never

        // Actions sit in the top bar, as in Pastebot's detail window, rather than in a bottom toolbar.
        // Each item has a title as well as a symbol: the symbol shows in the bar, and the title appears in the
        // overflow menu when the bar runs out of room, as on iPhone Duo. Copy is the main action, so it overflows last.
        let shareButton = UIBarButtonItem(title: NSLocalizedString("Share", comment: ""), image: UIImage(systemName: "square.and.arrow.up"), target: self, action: #selector(ClippingDetailViewController.shareItem(_:)), menu: nil)
        let copyButton = UIBarButtonItem(title: NSLocalizedString("Copy", comment: ""), image: UIImage(systemName: "doc.on.doc"), target: self, action: #selector(ClippingDetailViewController.copyItem(_:)), menu: nil)
        copyButton.visibilityPriority = .high

        var barButtonItems = [shareButton]

        if let copyAsMenu = self.pasteboardItem.makeCopyAsMenu()
        {
            let copyAsButton = UIBarButtonItem(title: NSLocalizedString("Copy As", comment: ""), image: UIImage(systemName: "textformat.abc"), target: nil, action: nil, menu: copyAsMenu)
            copyAsButton.visibilityPriority = .low
            barButtonItems.append(copyAsButton)
        }

        barButtonItems.append(copyButton)
        self.navigationItem.rightBarButtonItems = barButtonItems

        let contentStack = UIStackView(arrangedSubviews: self.makeContentViews())
        contentStack.axis = .vertical
        contentStack.spacing = 24
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)
        self.view.addSubview(scrollView)

        // The frame layout guide ignores insets, so the side margins are constants that viewDidLayoutSubviews()
        // widens to clear the safe area and any region the system reserves along a side.
        let contentLeftConstraint = contentStack.leftAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leftAnchor, constant: self.contentMargin)
        let contentRightConstraint = contentStack.rightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.rightAnchor, constant: -self.contentMargin)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: self.view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            contentLeftConstraint,
            contentRightConstraint
        ])

        self.scrollView = scrollView
        self.contentLeftConstraint = contentLeftConstraint
        self.contentRightConstraint = contentRightConstraint
    }

    override func viewDidLayoutSubviews()
    {
        super.viewDidLayoutSubviews()

        guard let scrollView = self.scrollView else { return }

        // Read at layout time, per physical edge: either side can carry a bar, and the two values are unrelated.
        let clearance = scrollView.sideClearanceForFrameGuideContent()

        if self.contentLeftConstraint?.constant != self.contentMargin + clearance.left
        {
            self.contentLeftConstraint?.constant = self.contentMargin + clearance.left
        }

        if self.contentRightConstraint?.constant != -(self.contentMargin + clearance.right)
        {
            self.contentRightConstraint?.constant = -(self.contentMargin + clearance.right)
        }
    }
}

private extension ClippingDetailViewController
{
    func makeContentViews() -> [UIView]
    {
        var views: [UIView] = [self.makeHeaderView()]

        if let image = self.pasteboardItem.preferredRepresentation?.imageValue
        {
            views.append(self.makeImageView(image))
            views.append(self.makeMetadataCapsule())
        }
        else
        {
            views.append(self.makeTextView())
            views.append(self.makeMetadataView())
        }

        return views
    }

    func makeHeaderView() -> UIView
    {
        let symbolName = self.pasteboardItem.preferredRepresentation?.type.symbolName ?? "doc"

        let iconView = UIImageView(image: UIImage(systemName: symbolName))
        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .center
        iconView.backgroundColor = .tertiarySystemFill
        iconView.layer.cornerRadius = 22
        iconView.clipsToBounds = true
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 44),
            iconView.heightAnchor.constraint(equalToConstant: 44)
        ])

        let titleText = self.pasteboardItem.preferredRepresentation?.type.localizedName ?? NSLocalizedString("Clipping", comment: "")
        let titleLabel = self.makeLabel(titleText, font: self.scaledFont(.title2, weight: .bold))
        let dateLabel = self.makeLabel(self.pasteboardItem.date.formatted(date: .abbreviated, time: .shortened), font: .preferredFont(forTextStyle: .footnote), color: .secondaryLabel)

        let titlesStack = UIStackView(arrangedSubviews: [titleLabel, dateLabel])
        titlesStack.axis = .vertical
        titlesStack.alignment = .leading
        titlesStack.spacing = 2

        let headerStack = UIStackView(arrangedSubviews: [iconView, titlesStack])
        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.spacing = 12
        return headerStack
    }

    func makeTextView() -> UIView
    {
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.dataDetectorTypes = [.link]

        if let attributedText = self.pasteboardItem.preferredRepresentation?.attributedStringValue
        {
            textView.attributedText = attributedText
        }
        else
        {
            textView.font = .preferredFont(forTextStyle: .body)
            textView.text = self.pasteboardItem.contentText
        }

        return textView
    }

    func makeImageView(_ image: UIImage) -> UIView
    {
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.layer.cornerRadius = 16
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: image.size.height / image.size.width)
        ])

        return imageView
    }

    /// Image metadata sits in a glass capsule beneath the image, as Pastebot's image clippings do.
    func makeMetadataCapsule() -> UIView
    {
        // The glass shapes itself from the corner configuration, so the view isn't clipped. It stays a capsule while
        // the metadata is short and keeps a 20 point radius once the rows wrap.
        let effectView = UIVisualEffectView(effect: UIGlassEffect())
        effectView.cornerConfiguration = .capsule(maximumRadius: 20)

        let metadataView = self.makeMetadataView()
        metadataView.translatesAutoresizingMaskIntoConstraints = false
        effectView.contentView.addSubview(metadataView)

        NSLayoutConstraint.activate([
            metadataView.topAnchor.constraint(equalTo: effectView.contentView.layoutMarginsGuide.topAnchor),
            metadataView.bottomAnchor.constraint(equalTo: effectView.contentView.layoutMarginsGuide.bottomAnchor),
            metadataView.leadingAnchor.constraint(equalTo: effectView.contentView.layoutMarginsGuide.leadingAnchor),
            metadataView.trailingAnchor.constraint(equalTo: effectView.contentView.layoutMarginsGuide.trailingAnchor)
        ])

        effectView.contentView.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        return effectView
    }

    /// Labels sit in a right-aligned column, and values follow them, as in Pastebot's metadata panel.
    func makeMetadataView() -> UIView
    {
        // Every label column takes the width of the widest label, so the column follows Dynamic Type and the
        // available width instead of a fixed number.
        var firstTitleLabel: UILabel?

        let rows: [UIView] = self.makeDetails().map { detail in
            let titleLabel = self.makeLabel(detail.title + ":", font: self.scaledFont(.footnote, weight: .semibold), color: .secondaryLabel)
            titleLabel.textAlignment = .right
            titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

            if let firstTitleLabel
            {
                titleLabel.widthAnchor.constraint(equalTo: firstTitleLabel.widthAnchor).isActive = true
            }
            else
            {
                firstTitleLabel = titleLabel
            }

            let valueLabel = self.makeLabel(detail.value, font: .preferredFont(forTextStyle: .footnote), color: .secondaryLabel)

            let rowStack = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
            rowStack.axis = .horizontal
            rowStack.alignment = .top
            rowStack.spacing = 12
            return rowStack
        }

        let metadataStack = UIStackView(arrangedSubviews: rows)
        metadataStack.axis = .vertical
        metadataStack.alignment = .leading
        metadataStack.spacing = 8
        return metadataStack
    }

    func makeLabel(_ text: String, font: UIFont, color: UIColor = .label) -> UILabel
    {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }

    func scaledFont(_ style: UIFont.TextStyle, weight: UIFont.Weight = .regular) -> UIFont
    {
        return UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: UIFont.preferredFont(forTextStyle: style).pointSize, weight: weight))
    }

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
