//
//  LinkPreviewStore.swift
//  ClipKit
//

import UIKit
import Combine
import LinkPresentation

/// Presentation helpers shared by the history list and the keyboard.
public extension PasteboardItem
{
    /// The web link this clipping holds, if any.
    var linkURL: URL? {
        return LinkPreviewStore.linkURL(for: self.preferredRepresentation)
    }

    /// The text this clipping shows before any link preview arrives.
    var contentText: String? {
        guard let representation = self.preferredRepresentation else { return nil }
        return representation.stringValue ?? representation.attributedStringValue?.string ?? representation.urlValue?.absoluteString
    }

    /// A short relative age, such as "now", "36s", "5m", or "2d".
    func ageText(relativeTo now: Date = Date()) -> String
    {
        if now.timeIntervalSince(self.date) < 2
        {
            return NSLocalizedString("now", comment: "")
        }

        return PasteboardItem.ageFormatter.string(from: self.date, to: now) ?? ""
    }

    private static let ageFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.second, .minute, .hour, .day]
        return formatter
    }()
}

private struct AppStoreSearchResponse: Decodable
{
    var results: [AppStoreResult]
}

private struct AppStoreResult: Decodable
{
    var trackName: String?
    var sellerName: String?
    var sellerUrl: URL?
    var artworkUrl512: URL?

    /// Whether the developer's website is the link's site, or the site is a subdomain of it.
    func isOperated(by host: String) -> Bool
    {
        guard let sellerHost = self.sellerUrl?.host?.lowercased() else { return false }
        return host == sellerHost || host.hasSuffix("." + sellerHost) || sellerHost.hasSuffix("." + host)
    }

    /// Whether the brand is a whole word in the app's name or seller name.
    func isNamed(_ brand: String) -> Bool
    {
        return [self.trackName, self.sellerName].contains { name in
            name?.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0 == brand } == true
        }
    }
}

public struct LinkPreview
{
    public var title: String?
    public var icon: UIImage?
}

/// Fetches titles and site icons for web links.
///
/// Fetching only happens when a row for a link is displayed, and only when Generate Link Previews is on.
/// Clipboard monitoring never calls into this store.
@MainActor
public final class LinkPreviewStore: ObservableObject
{
    public static let shared = LinkPreviewStore()

    @Published public private(set) var previews = [URL: LinkPreview]()

    private var pendingURLs = Set<URL>()

    private init()
    {
    }
}

public extension LinkPreviewStore
{
    /// Returns the web link a clipping holds, if any.
    nonisolated static func linkURL(for representation: PasteboardItemRepresentation?) -> URL?
    {
        let candidate: URL?

        switch representation?.type
        {
        case .url: candidate = representation?.urlValue
        case .text: candidate = URL(string: representation?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        default: candidate = nil
        }

        guard let url = candidate, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    func preview(for url: URL) -> LinkPreview?
    {
        return self.previews[url]
    }

    func fetchPreviewIfNeeded(for url: URL)
    {
        guard UserDefaults.shared.generateLinkPreviews else { return }
        guard self.previews[url] == nil, !self.pendingURLs.contains(url) else { return }

        self.pendingURLs.insert(url)

        let metadataProvider = LPMetadataProvider()
        metadataProvider.timeout = 10
        metadataProvider.startFetchingMetadata(for: url) { (metadata, error) in
            Task { @MainActor in
                await self.finishFetching(url: url, metadata: metadata)
            }
        }
    }
}

private extension LinkPreviewStore
{
    func finishFetching(url: URL, metadata: LPLinkMetadata?) async
    {
        self.pendingURLs.remove(url)

        // Failed fetches are cached as empty so a row doesn't retry on every redraw.
        var preview = LinkPreview(title: metadata?.title, icon: nil)
        // A matching App Store icon beats the site's icon, since it's the app people recognize.
        if let appIcon = await self.loadAppIcon(for: url)
        {
            preview.icon = appIcon
        }
        else
        {
            preview.icon = await self.loadIcon(from: metadata?.iconProvider)
        }
        self.previews[url] = preview
    }

    /// Looks up the App Store icon for the brand in a link's domain, such as GitHub for github.com.
    /// An app counts when its developer's website is the link's site, or when the brand is a word in its name.
    func loadAppIcon(for url: URL) async -> UIImage?
    {
        guard let host = url.host?.lowercased() else { return nil }

        let labels = host.split(separator: ".")
        guard labels.count >= 2 else { return nil }

        let brand = String(labels[labels.count - 2])
        guard brand.count >= 3 else { return nil }

        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: brand),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "country", value: "us")
        ]

        guard let searchURL = components?.url else { return nil }

        do
        {
            let (data, _) = try await URLSession.shared.data(from: searchURL)
            let response = try JSONDecoder().decode(AppStoreSearchResponse.self, from: data)

            // The developer's own site is the stronger signal, so the name only decides when no app comes from that site.
            guard let app = response.results.first(where: { $0.isOperated(by: host) })
                ?? response.results.first(where: { $0.isNamed(brand) }),
                let artworkURL = app.artworkUrl512 else { return nil }

            let (artworkData, _) = try await URLSession.shared.data(from: artworkURL)
            return UIImage(data: artworkData)
        }
        catch
        {
            return nil
        }
    }

    func loadIcon(from provider: NSItemProvider?) async -> UIImage?
    {
        guard let provider, provider.canLoadObject(ofClass: UIImage.self) else { return nil }

        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            provider.loadObject(ofClass: UIImage.self) { (image, error) in
                continuation.resume(returning: image as? UIImage)
            }
        }
    }
}
