//
//  DemoClippings.swift
//  Clipboard
//
//  Debug builds only. Fills an empty history with sample clippings so every screen can be
//  reviewed and screenshotted in the simulator, which can't capture copies from other apps.
//
//      simctl launch <device> com.oliverames.clipboard -ClipboardDemoData YES
//
//  Add -ClipboardSkipOnboarding YES to go straight to the history, or NO to show onboarding again.
//  Add -ClipboardDemoScreen <name> to open one screen; HistoryViewController lists the names.
//

#if DEBUG

import UIKit
import CoreData
import CoreLocation

import ClipboardKit

enum DemoClippings
{
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "ClipboardDemoData") }

    static func skipOnboardingIfRequested()
    {
        guard let skip = UserDefaults.standard.object(forKey: "ClipboardSkipOnboarding") as? String else { return }
        UserDefaults.shared.hasCompletedOnboarding = (skip == "YES")
    }

    static func seedIfRequested()
    {
        guard self.isRequested else { return }

        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        context.perform {
            let request = PasteboardItem.fetchRequest() as NSFetchRequest<PasteboardItem>
            guard (try? context.count(for: request)) == 0 else { return }

            self.seed(in: context)
        }
    }
}

private extension DemoClippings
{
    struct Sample
    {
        var object: NSItemProviderWriting
        var minutesAgo: Double
        var isFavorite = false
        var isPinned = false
        var isTrashed = false
        var listName: String?
        var location: CLLocation?
    }

    static func seed(in context: NSManagedObjectContext)
    {
        let burlington = CLLocation(latitude: 44.4759, longitude: -73.2121)
        let montpelier = CLLocation(latitude: 44.2601, longitude: -72.5754)

        let code = """
        func greet(_ name: String) -> String {
            let greeting = "Hello, \\(name)!"
            return greeting
        }
        """

        let json = #"{"name":"Clipboard","version":2,"tags":["history","ios"]}"#

        let richText = NSAttributedString(string: "Meeting moved to Thursday at 3 PM. Bring the Q4 numbers.", attributes: [.font: UIFont.boldSystemFont(ofSize: 17)])

        let samples: [Sample] = [
            Sample(object: "The quick brown fox jumps over the lazy dog." as NSString, minutesAgo: 1, location: burlington),
            Sample(object: NSURL(string: "https://developer.apple.com/design/human-interface-guidelines/")!, minutesAgo: 4, isFavorite: true),
            Sample(object: self.makeImage(), minutesAgo: 9, location: montpelier),
            Sample(object: code as NSString, minutesAgo: 16, isPinned: true, listName: "Snippets"),
            Sample(object: "Order #48213 ships Tuesday" as NSString, minutesAgo: 34, isPinned: true),
            Sample(object: richText, minutesAgo: 52, isFavorite: true, listName: "Work"),
            Sample(object: json as NSString, minutesAgo: 75, listName: "Snippets"),
            Sample(object: "oliver@example.com" as NSString, minutesAgo: 140, location: burlington),
            Sample(object: NSURL(string: "https://github.com/rileytestut/Clip")!, minutesAgo: 300),
            Sample(object: "128 Church Street\nBurlington, VT 05401" as NSString, minutesAgo: 600, isFavorite: true, location: burlington),
            Sample(object: "Here's to the crazy ones. The misfits. The rebels. The troublemakers. The round pegs in the square holes. The ones who see things differently." as NSString, minutesAgo: 1_500),
            Sample(object: "Old draft text" as NSString, minutesAgo: 3_000, isTrashed: true)
        ]

        var lists = [String: ClippingList]()
        let group = DispatchGroup()

        for sample in samples
        {
            group.enter()

            let provider = NSItemProvider(object: sample.object)
            PasteboardItemRepresentation.representations(for: provider, in: context) { representations in
                defer { group.leave() }
                guard let item = PasteboardItem(representations: representations, context: context) else { return }

                item.setValue(Date().addingTimeInterval(-sample.minutesAgo * 60), forKey: #keyPath(PasteboardItem.date))
                item.isFavorite = sample.isFavorite
                item.isPinned = sample.isPinned
                item.location = sample.location
                item.trashedDate = sample.isTrashed ? Date() : nil

                if let listName = sample.listName
                {
                    let list = lists[listName] ?? ClippingList(name: listName, context: context)
                    lists[listName] = list
                    item.mutableSetValue(forKey: "lists").add(list)
                }
            }
        }

        group.notify(queue: .global()) {
            context.perform {
                do
                {
                    try context.save()
                }
                catch
                {
                    print("Failed to save demo clippings.", error)
                }
            }
        }
    }

    static func makeImage() -> UIImage
    {
        let size = CGSize(width: 600, height: 400)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor.systemOrange.cgColor, UIColor.systemPink.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])

            UIColor.white.withAlphaComponent(0.85).setFill()
            UIBezierPath(ovalIn: CGRect(x: 380, y: 60, width: 120, height: 120)).fill()
            UIBezierPath(roundedRect: CGRect(x: 60, y: 260, width: 480, height: 80), cornerRadius: 40).fill()
        }
    }
}

#endif
