//
//  LinkPreviewCache.swift
//  ClipboardKit
//
//  Persists link previews to disk.
//
//  Site icons and titles rarely change, so keeping them on disk means the app
//  doesn't have to ask the network for them again every time it launches.
//

import UIKit
import Foundation

/// A cached link preview, as stored on disk.
struct LinkPreviewEntry: Codable
{
    var url: String
    var title: String?
    var iconFileName: String?
    var date: Date

    init(url: String, title: String?, iconFileName: String?, date: Date = Date())
    {
        self.url = url
        self.title = title
        self.iconFileName = iconFileName
        self.date = date
    }
}

/// Stores link previews as an index file plus one image per icon.
final class LinkPreviewCache
{
    /// How many previews to keep. Older ones are dropped so the cache can't grow forever.
    private let maximumEntries = 200

    /// Icons are small, but a very old icon isn't worth keeping around.
    private let maximumAge: TimeInterval = 60 * 60 * 24 * 30

    private let directory: URL
    private let indexURL: URL

    private let queue = DispatchQueue(label: "com.oliverames.clipboard.linkpreviewcache", qos: .utility)

    init()
    {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.oliverames.clipboard")
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())

        self.directory = base.appendingPathComponent("LinkPreviews", isDirectory: true)
        self.indexURL = self.directory.appendingPathComponent("index.json")

        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: nil)
    }
}

extension LinkPreviewCache
{
    /// Reads every cached preview from disk.
    func loadEntries(completion: @escaping ([LinkPreviewEntry]) -> Void)
    {
        self.queue.async {
            let entries: [LinkPreviewEntry]

            if let data = try? Data(contentsOf: self.indexURL),
               let decoded = try? JSONDecoder().decode([LinkPreviewEntry].self, from: data)
            {
                entries = decoded
            }
            else
            {
                entries = []
            }

            completion(entries)
        }
    }

    /// Saves a preview, replacing any earlier version of it.
    func save(entry: LinkPreviewEntry, icon: UIImage?, completion: (() -> Void)? = nil)
    {
        self.queue.async {
            var entries = self.currentEntries()
            entries.removeAll { $0.url == entry.url }

            var entry = entry
            entry.date = Date()

            if let icon = icon, let data = icon.pngData()
            {
                let fileName = self.fileName(for: entry.url)
                let fileURL = self.directory.appendingPathComponent(fileName)

                if (try? data.write(to: fileURL, options: .atomic)) != nil
                {
                    entry.iconFileName = fileName
                }
            }

            entries.append(entry)
            self.prune(entries)
            self.write(entries)

            completion?()
        }
    }

    /// Loads a cached icon from disk.
    func icon(named fileName: String) -> UIImage?
    {
        guard let data = try? Data(contentsOf: self.directory.appendingPathComponent(fileName)) else { return nil }
        return UIImage(data: data)
    }
}

private extension LinkPreviewCache
{
    func currentEntries() -> [LinkPreviewEntry]
    {
        guard let data = try? Data(contentsOf: self.indexURL),
              let decoded = try? JSONDecoder().decode([LinkPreviewEntry].self, from: data) else { return [] }

        return decoded
    }

    func write(_ entries: [LinkPreviewEntry])
    {
        let entries = entries.sorted { $0.date > $1.date }
        let data = try? JSONEncoder().encode(entries)

        if let data = data
        {
            try? data.write(to: self.indexURL, options: .atomic)
        }
    }

    /// Drops the oldest previews, and any icons that are no longer referenced.
    func prune(_ entries: [LinkPreviewEntry])
    {
        var entries = entries.sorted { $0.date > $1.date }

        if entries.count > self.maximumEntries
        {
            entries = Array(entries.prefix(self.maximumEntries))
        }

        let expirationDate = Date().addingTimeInterval(-self.maximumAge)
        let expired = entries.filter { $0.date < expirationDate }
        entries.removeAll { $0.date < expirationDate }

        for entry in expired
        {
            if let fileName = entry.iconFileName
            {
                try? FileManager.default.removeItem(at: self.directory.appendingPathComponent(fileName))
            }
        }

        let referenced = Set(entries.compactMap { $0.iconFileName })

        if let files = try? FileManager.default.contentsOfDirectory(atPath: self.directory.path)
        {
            for file in files where file.hasSuffix(".png") && !referenced.contains(file)
            {
                try? FileManager.default.removeItem(at: self.directory.appendingPathComponent(file))
            }
        }
    }

    /// A stable, unique file name for a URL's icon.
    func fileName(for url: String) -> String
    {
        var hash: UInt64 = 5381
        for byte in url.utf8
        {
            hash = (hash &* 33) &+ UInt64(byte)
        }

        return String(format: "%016llx.png", hash)
    }
}
