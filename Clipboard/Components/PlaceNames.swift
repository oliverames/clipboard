//
//  PlaceNames.swift
//  Clipboard
//
//  Town names for tagged clippings. A name comes from Apple Maps, which receives the clipping's
//  coordinates, so each clipping is looked up at most once. The name is stored on the clipping
//  itself, so it's deleted along with the clipping.
//

import Foundation
import CoreData
import CoreLocation

import ClipboardKit

@MainActor
enum PlaceNames
{
    /// Where names were kept before they moved onto the clipping. Read once to migrate, then removed.
    private static let legacyDefaultsKey = "PlaceNamesByClipping"

    private static var pending = Set<NSManagedObjectID>()

    /// The saved name, without any network request.
    static func cachedName(for item: PasteboardItem) -> String?
    {
        return item.placeName
    }

    /// The saved name, or one looked up once from Apple Maps and saved on the clipping.
    static func name(for item: PasteboardItem) async -> String?
    {
        if let name = item.placeName
        {
            return name
        }

        // A lookup already in flight will fill in the name.
        guard let location = item.location, !self.pending.contains(item.objectID) else { return nil }
        self.pending.insert(item.objectID)
        defer { self.pending.remove(item.objectID) }

        // The location isn't precise, so name the town rather than a street address.
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }

        let name = [placemark.locality, placemark.administrativeArea].compactMap { $0 }.joined(separator: ", ")
        guard !name.isEmpty, !item.isDeleted, item.managedObjectContext != nil else { return nil }

        item.placeName = name
        self.save(item.managedObjectContext)
        return name
    }

    /// Moves names from the old defaults cache onto their clippings, drops names whose clipping is gone,
    /// and removes the old cache. Run once the database is ready.
    static func migrateLegacyCache(in context: NSManagedObjectContext)
    {
        guard let legacy = UserDefaults.standard.dictionary(forKey: self.legacyDefaultsKey) as? [String: String] else { return }

        let coordinator = context.persistentStoreCoordinator

        for (key, name) in legacy
        {
            guard let url = URL(string: key),
                  let objectID = coordinator?.managedObjectID(forURIRepresentation: url),
                  let item = try? context.existingObject(with: objectID) as? PasteboardItem,
                  item.placeName == nil
            else { continue }

            item.placeName = name
        }

        self.save(context)
        UserDefaults.standard.removeObject(forKey: self.legacyDefaultsKey)
    }

    private static func save(_ context: NSManagedObjectContext?)
    {
        guard let context, context.hasChanges else { return }

        do
        {
            try context.save()
        }
        catch
        {
            print("Failed to save place name.", error)
        }
    }
}
