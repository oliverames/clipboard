//
//  ClippingDetailViewController.swift
//  Clip
//

import UIKit

import ClipKit

class ClippingDetailViewController: UIViewController
{
    private let pasteboardItem: PasteboardItem

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
        var barButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), style: .plain, target: self, action: #selector(ClippingDetailViewController.shareItem(_:)))
        ]

        if let copyAsMenu = self.pasteboardItem.makeCopyAsMenu()
        {
            barButtonItems.append(UIBarButtonItem(image: UIImage(systemName: "textformat.abc"), menu: copyAsMenu))
        }

        barButtonItems.append(UIBarButtonItem(image: UIImage(systemName: "doc.on.doc"), style: .plain, target: self, action: #selector(ClippingDetailViewController.copyItem(_:))))
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

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: self.view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20)
        ])
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
        let effectView = UIVisualEffectView(effect: UIGlassEffect())
        effectView.layer.cornerRadius = 20
        effectView.clipsToBounds = true

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
        let rows: [UIView] = self.makeDetails().map { detail in
            let titleLabel = self.makeLabel(detail.title + ":", font: self.scaledFont(.footnote, weight: .semibold), color: .secondaryLabel)
            titleLabel.textAlignment = .right
            titleLabel.setContentHuggingPriority(.required, for: .horizontal)
            titleLabel.widthAnchor.constraint(equalToConstant: 110).isActive = true

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
