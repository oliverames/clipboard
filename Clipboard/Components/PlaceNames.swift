//
//  PlaceNames.swift
//  Clipboard
//
//  Town names for tagged clippings. A name comes from Apple Maps, which receives the clipping's
//  coordinates, so each clipping is looked up at most once and the name is kept on this device.
//

import Foundation
import CoreLocation

import ClipboardKit

@MainActor
enum PlaceNames
{
    private static let defaultsKey = "PlaceNamesByClipping"

    private static var cache: [String: String] = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    private static var pending = Set<String>()

    private static func key(for item: PasteboardItem) -> String
    {
        return item.objectID.uriRepresentation().absoluteString
    }

    /// The saved name, without any network request.
    static func cachedName(for item: PasteboardItem) -> String?
    {
        return self.cache[self.key(for: item)]
    }

    /// The saved name, or one looked up once from Apple Maps and saved for next time.
    static func name(for item: PasteboardItem) async -> String?
    {
        let key = self.key(for: item)

        if let name = self.cache[key]
        {
            return name
        }

        // Temporary IDs change on save, and a lookup already in flight will fill the cache.
        guard let location = item.location, !item.objectID.isTemporaryID, !self.pending.contains(key) else { return nil }
        self.pending.insert(key)
        defer { self.pending.remove(key) }

        // The location isn't precise, so name the town rather than a street address.
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }

        let name = [placemark.locality, placemark.administrativeArea].compactMap { $0 }.joined(separator: ", ")
        guard !name.isEmpty else { return nil }

        self.cache[key] = name
        UserDefaults.standard.set(self.cache, forKey: self.defaultsKey)
        return name
    }
}
