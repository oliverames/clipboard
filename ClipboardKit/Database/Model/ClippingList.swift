//
//  ClippingList.swift
//  ClipboardKit
//

import CoreData

@objc(ClippingList)
public class ClippingList: NSManagedObject
{
    /* Properties */
    @NSManaged public var name: String
    @NSManaged public private(set) var date: Date?

    /* Relationships */
    @nonobjc public var items: Set<PasteboardItem> {
        return self._items as? Set<PasteboardItem> ?? []
    }
    @NSManaged @objc(items) private var _items: NSSet?

    private override init(entity: NSEntityDescription, insertInto context: NSManagedObjectContext?)
    {
        super.init(entity: entity, insertInto: context)
    }

    public init(name: String, context: NSManagedObjectContext)
    {
        super.init(entity: ClippingList.entity(), insertInto: context)

        self.name = name
        self.date = Date()
    }
}

public extension ClippingList
{
    @nonobjc class func fetchRequest() -> NSFetchRequest<ClippingList>
    {
        return NSFetchRequest<ClippingList>(entityName: "ClippingList")
    }
}
