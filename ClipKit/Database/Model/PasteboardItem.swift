//
//  PasteboardItem.swift
//  Clip
//
//  Created by Riley Testut on 6/11/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import CoreData
import MobileCoreServices
import CoreLocation

private extension PasteboardItemRepresentation.RepresentationType
{
    var priority: Int {
        switch self
        {
        case .attributedText: return 0
        case .text: return 1
        case .url: return 2
        case .image: return 3
        }
    }
}

@objc(PasteboardItem)
public class PasteboardItem: NSManagedObject, Identifiable
{
    /* Properties */
    @NSManaged public private(set) var date: Date
    @NSManaged public var isMarkedForDeletion: Bool
    @NSManaged public var isFavorite: Bool
    @NSManaged public var isPinned: Bool
    @NSManaged public var trashedDate: Date?

    public var location: CLLocation? {
        get {
            guard let latitude, let longitude else { return nil }
            
            let coordinate = CLLocation(latitude: latitude.doubleValue, longitude: longitude.doubleValue)
            return coordinate
        }
        set {
            self.latitude = newValue?.coordinate.latitude as? NSNumber
            self.longitude = newValue?.coordinate.longitude as? NSNumber
        }
    }
    @NSManaged private var latitude: NSNumber?
    @NSManaged private var longitude: NSNumber?
    
    /* Relationships */
    @nonobjc public var representations: [PasteboardItemRepresentation] {
        return self._representations.array as! [PasteboardItemRepresentation]
    }
    @NSManaged @objc(representations) private var _representations: NSOrderedSet
    
    @NSManaged public var preferredRepresentation: PasteboardItemRepresentation?

    @nonobjc public var lists: Set<ClippingList> {
        return self._lists as? Set<ClippingList> ?? []
    }
    @NSManaged @objc(lists) private var _lists: NSSet?

    private override init(entity: NSEntityDescription, insertInto context: NSManagedObjectContext?)
    {
        super.init(entity: entity, insertInto: context)
    }
    
    public init?(representations: [PasteboardItemRepresentation], context: NSManagedObjectContext)
    {
        guard !representations.isEmpty else { return nil }
        
        super.init(entity: PasteboardItem.entity(), insertInto: context)
        
        self._representations = NSOrderedSet(array: representations)
        
        let prioritizedRepresentationTypes = PasteboardItemRepresentation.RepresentationType.allCases.sorted { $0.priority > $1.priority }
        for type in prioritizedRepresentationTypes
        {
            guard let representation = representations.first(where: { $0.type == type }) else { continue }
            
            self.preferredRepresentation = representation
            break
        }
    }
    
    override public func awakeFromInsert()
    {
        super.awakeFromInsert()
        
        self.date = Date()
    }
}

public extension PasteboardItem
{
    @nonobjc class func fetchRequest() -> NSFetchRequest<PasteboardItem>
    {
        return NSFetchRequest<PasteboardItem>(entityName: "PasteboardItem")
    }
    
    /// Recent clippings outside the Trash, with pinned clippings first.
    class func historyFetchRequest() -> NSFetchRequest<PasteboardItem>
    {
        let fetchRequest = PasteboardItem.fetchRequest() as NSFetchRequest<PasteboardItem>
        fetchRequest.predicate = NSPredicate(format: "%K == NO AND trashedDate == nil", #keyPath(PasteboardItem.isMarkedForDeletion))
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \PasteboardItem.isPinned, ascending: false), NSSortDescriptor(keyPath: \PasteboardItem.date, ascending: false)]
        fetchRequest.fetchLimit = UserDefaults.shared.historyLimit.rawValue
        return fetchRequest
    }

    /// Clippings the history limit never purges: favorites, trashed items, and items in a list.
    class func protectedFetchRequest() -> NSFetchRequest<PasteboardItem>
    {
        let fetchRequest = PasteboardItem.fetchRequest() as NSFetchRequest<PasteboardItem>
        fetchRequest.predicate = NSPredicate(format: "%K == NO AND (isFavorite == YES OR trashedDate != nil OR lists.@count > 0)", #keyPath(PasteboardItem.isMarkedForDeletion))
        return fetchRequest
    }

    class func trashFetchRequest() -> NSFetchRequest<PasteboardItem>
    {
        let fetchRequest = PasteboardItem.fetchRequest() as NSFetchRequest<PasteboardItem>
        fetchRequest.predicate = NSPredicate(format: "%K == NO AND trashedDate != nil", #keyPath(PasteboardItem.isMarkedForDeletion))
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \PasteboardItem.trashedDate, ascending: false)]
        return fetchRequest
    }
}

// SwiftUI
extension PasteboardItem
{
    class func make(item: NSItemProviderWriting, date: Date = Date(), context: NSManagedObjectContext) -> PasteboardItem
    {
        let itemProvider = NSItemProvider(object: item)
        let semaphore = DispatchSemaphore(value: 0)
        
        let childContext = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        var objectID: NSManagedObjectID!
        
        PasteboardItemRepresentation.representations(for: itemProvider, in: childContext) { (representations) in
            let item = PasteboardItem(representations: representations, context: childContext)!
            item.date = date
            
            try! childContext.obtainPermanentIDs(for: [item])
            objectID = item.objectID
            
            try! childContext.save()
            semaphore.signal()
        }
        semaphore.wait()
                
        let pasteboardItem = context.object(with: objectID) as! PasteboardItem
        return pasteboardItem
    }
}
