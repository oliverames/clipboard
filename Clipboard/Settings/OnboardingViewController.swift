//
//  OnboardingViewController.swift
//  Clipboard
//

import UIKit

private struct OnboardingStep
{
    var title: String
    var detail: String
    var settingsButtonTitle: String?
}

class OnboardingViewController: UIViewController
{
    var onFinish: (() -> Void)?

    private let contentMargin: CGFloat = 24

    private weak var scrollView: UIScrollView?
    private var contentLeftConstraint: NSLayoutConstraint?
    private var contentRightConstraint: NSLayoutConstraint?

    override func viewDidLoad()
    {
        super.viewDidLoad()

        self.view.backgroundColor = .systemBackground

        let steps = [
            OnboardingStep(title: NSLocalizedString("Allow paste access", comment: ""),
                 detail: NSLocalizedString("Go to Settings, then Privacy & Security, then Paste from Other Apps, then Clipboard, and choose Allow. This option appears after Clipboard reads the clipboard once.", comment: ""),
                 settingsButtonTitle: NSLocalizedString("Open Settings", comment: "")),
            OnboardingStep(title: NSLocalizedString("Keep monitoring in the background", comment: ""),
                 detail: NSLocalizedString("Go to Settings, then Clipboard, then Location, and choose Always. This lets Clipboard keep watching while it's closed.", comment: ""),
                 settingsButtonTitle: NSLocalizedString("Open Settings", comment: "")),
            OnboardingStep(title: NSLocalizedString("Let Shortcuts read clippings (optional)", comment: ""),
                 detail: NSLocalizedString("In Clipboard's settings, turn on Allow Shortcuts Access. Locked devices never return clipboard history.", comment: ""),
                 settingsButtonTitle: nil)
        ]

        let titleLabel = self.makeLabel(NSLocalizedString("Welcome to Clipboard", comment: ""), style: .largeTitle, weight: .bold)
        let subtitleLabel = self.makeLabel(NSLocalizedString("Clipboard keeps a history of everything you copy. It all stays on this iPhone.", comment: ""), style: .body, color: .secondaryLabel)

        let stepViews = steps.enumerated().map { (index, step) in self.makeStepView(number: index + 1, step: step) }

        let stepsStack = UIStackView(arrangedSubviews: stepViews)
        stepsStack.axis = .vertical
        stepsStack.spacing = 24

        var doneConfiguration = UIButton.Configuration.prominentGlass()
        doneConfiguration.title = NSLocalizedString("Get Started", comment: "")
        let doneButton = UIButton(configuration: doneConfiguration, primaryAction: UIAction { [weak self] _ in
            self?.onFinish?()
        })

        let contentStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, stepsStack, doneButton])
        contentStack.axis = .vertical
        contentStack.spacing = 28
        contentStack.setCustomSpacing(40, after: stepsStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = UIScrollView()
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

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 40),
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

private extension OnboardingViewController
{
    func makeLabel(_ text: String, style: UIFont.TextStyle, weight: UIFont.Weight = .regular, color: UIColor = .label) -> UILabel
    {
        let label = UILabel()
        label.text = text
        label.font = UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: UIFont.preferredFont(forTextStyle: style).pointSize, weight: weight))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    func makeStepView(number: Int, step: OnboardingStep) -> UIView
    {
        let numberLabel = UILabel()
        numberLabel.text = "\(number)"
        numberLabel.font = .preferredFont(forTextStyle: .headline)
        numberLabel.textAlignment = .center
        numberLabel.textColor = .white
        numberLabel.backgroundColor = .systemBlue
        numberLabel.clipsToBounds = true
        numberLabel.layer.cornerRadius = 14
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            numberLabel.widthAnchor.constraint(equalToConstant: 28),
            numberLabel.heightAnchor.constraint(equalToConstant: 28)
        ])

        var textViews: [UIView] = [
            self.makeLabel(step.title, style: .headline, weight: .semibold),
            self.makeLabel(step.detail, style: .subheadline, color: .secondaryLabel)
        ]

        if let settingsButtonTitle = step.settingsButtonTitle
        {
            var configuration = UIButton.Configuration.tinted()
            configuration.title = settingsButtonTitle
            configuration.cornerStyle = .capsule
            let settingsButton = UIButton(configuration: configuration, primaryAction: UIAction { _ in
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            })
            textViews.append(settingsButton)
        }

        let textStack = UIStackView(arrangedSubviews: textViews)
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 6

        let stepStack = UIStackView(arrangedSubviews: [numberLabel, textStack])
        stepStack.axis = .horizontal
        stepStack.alignment = .top
        stepStack.spacing = 12
        return stepStack
    }
}
