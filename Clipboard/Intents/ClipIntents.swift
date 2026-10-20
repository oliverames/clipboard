//
//  ClipIntents.swift
//  Clipboard
//

import AppIntents

import ClipboardKit

private extension DatabaseManager
{
    func prepareStore() async throws
    {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.prepare { continuation.resume(with: $0) }
        }
    }
}

enum ClipIntentError: LocalizedError
{
    case noClippings
    case latestClippingIsNotText
    case shortcutsAccessDisabled

    var errorDescription: String? {
        switch self
        {
        case .noClippings: return NSLocalizedString("There are no clippings in Clipboard yet.", comment: "")
        case .latestClippingIsNotText: return NSLocalizedString("The latest clipping in Clipboard isn't text.", comment: "")
        case .shortcutsAccessDisabled: return NSLocalizedString("Shortcuts access is off. Turn on Allow Shortcuts Access in Clipboard's settings.", comment: "")
        }
    }
}

struct SaveClipboardIntent: AppIntent
{
    static let title: LocalizedStringResource = "Save Clipboard"
    static let description = IntentDescription("Saves the current clipboard contents to Clipboard.")

    // Reading the clipboard requires the app to be in the foreground.
    static var supportedModes: IntentModes { .foreground }

    func perform() async throws -> some IntentResult & ProvidesDialog
    {
        try await DatabaseManager.shared.prepareStore()

        do
        {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DatabaseManager.shared.savePasteboard(location: ApplicationMonitor.shared.locationManager.location) { continuation.resume(with: $0) }
            }
        }
        catch PasteboardError.duplicateItem
        {
            return .result(dialog: "That clipboard item is already in Clipboard.")
        }

        return .result(dialog: "Saved the clipboard to Clipboard.")
    }
}

struct GetLatestClippingIntent: AppIntent
{
    static let title: LocalizedStringResource = "Get Latest Clipping"
    static let description = IntentDescription("Returns the most recent clipping saved in Clipboard.")

    // Clipboard history is sensitive, so this never runs on a locked device.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    func perform() async throws -> some ReturnsValue<String>
    {
        guard UserDefaults.shared.allowsShortcutsHistory else { throw ClipIntentError.shortcutsAccessDisabled }

        try await DatabaseManager.shared.prepareStore()

        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let text: String = try await context.perform {
            let fetchRequest = PasteboardItem.historyFetchRequest()
            fetchRequest.fetchLimit = 1

            guard let item = try context.fetch(fetchRequest).first else { throw ClipIntentError.noClippings }
            guard let representation = item.preferredRepresentation,
                  let text = representation.stringValue ?? representation.attributedStringValue?.string ?? representation.urlValue?.absoluteString
            else { throw ClipIntentError.latestClippingIsNotText }

            return text
        }

        return .result(value: text)
    }
}

struct ClipShortcuts: AppShortcutsProvider
{
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SaveClipboardIntent(),
            phrases: ["Save my clipboard in \(.applicationName)", "Save to \(.applicationName)"],
            shortTitle: "Save Clipboard",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: GetLatestClippingIntent(),
            phrases: ["Get my latest clipping from \(.applicationName)"],
            shortTitle: "Latest Clipping",
            systemImageName: "doc.on.clipboard"
        )
    }
}
