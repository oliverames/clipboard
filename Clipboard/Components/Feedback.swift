//
//  Feedback.swift
//  Clipboard
//
//  Haptics and the brief confirmation that appears after a copy.
//

import UIKit

enum Haptics
{
    /// A copy or another action that finished.
    static func success()
    {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// A toggle, such as favorite or pin, or a change of filter or layout.
    static func selection()
    {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Something left the list, such as a clipping moved to the Trash.
    static func impact()
    {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// A destructive action the person confirmed.
    static func warning()
    {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

/// A glass capsule that confirms an action, then fades. VoiceOver hears the same message.
final class ToastView: UIVisualEffectView
{
    private static weak var current: ToastView?

    private let label = UILabel()

    static func show(_ message: String, systemImage: String = "checkmark.circle.fill", in hostView: UIView)
    {
        UIAccessibility.post(notification: .announcement, argument: message)

        self.current?.removeFromSuperview()

        let toast = ToastView(message: message, systemImage: systemImage)
        toast.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(toast)

        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: hostView.safeAreaLayoutGuide.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: hostView.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            toast.leadingAnchor.constraint(greaterThanOrEqualTo: hostView.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            toast.trailingAnchor.constraint(lessThanOrEqualTo: hostView.safeAreaLayoutGuide.trailingAnchor, constant: -16)
        ])

        self.current = toast

        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        toast.alpha = 0
        toast.transform = reduceMotion ? .identity : CGAffineTransform(translationX: 0, y: 12).scaledBy(x: 0.9, y: 0.9)

        UIView.animate(withDuration: reduceMotion ? 0.2 : 0.45, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
            toast.alpha = 1
            toast.transform = .identity
        }

        UIView.animate(withDuration: 0.3, delay: 1.6, options: [.beginFromCurrentState, .allowUserInteraction]) {
            toast.alpha = 0
        } completion: { _ in
            toast.removeFromSuperview()
        }
    }

    private init(message: String, systemImage: String)
    {
        super.init(effect: UIGlassEffect())

        self.cornerConfiguration = .capsule()
        self.isUserInteractionEnabled = false
        self.isAccessibilityElement = false

        let imageView = UIImageView(image: UIImage(systemName: systemImage))
        imageView.tintColor = .systemGreen
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .headline)
        imageView.setContentHuggingPriority(.required, for: .horizontal)

        self.label.text = message
        self.label.font = .preferredFont(forTextStyle: .headline)
        self.label.adjustsFontForContentSizeCategory = true
        self.label.numberOfLines = 0

        let stackView = UIStackView(arrangedSubviews: [imageView, self.label])
        stackView.spacing = 8
        stackView.alignment = .center
        stackView.translatesAutoresizingMaskIntoConstraints = false
        self.contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 12),
            stackView.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -12),
            stackView.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor, constant: -20)
        ])
    }

    required init?(coder: NSCoder)
    {
        fatalError("init(coder:) has not been implemented")
    }
}

extension UIViewController
{
    /// Confirms an action with a haptic and a toast, such as after a copy.
    func confirm(_ message: String = NSLocalizedString("Copied", comment: ""), systemImage: String = "checkmark.circle.fill")
    {
        Haptics.success()

        // The view's safe area already clears the tab bar or toolbar, so the toast sits just above either.
        guard let hostView = self.viewIfLoaded else { return }
        ToastView.show(message, systemImage: systemImage, in: hostView)
    }
}
