//
//  DatabaseManager.swift
//  Clipboard
//
//  Created by Riley Testut on 6/11/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import CoreData
import CoreLocation

import Roxas

private extension UserDefaults
{
    @NSManaged var previousHistoryToken: Data?
}

public enum PasteboardError: LocalizedError
{
    case unsupportedImageFormat
    case unsupportedItem
    case noItem
    case duplicateItem
    
    public var errorDescription: String? {
        switch self
        {
        case .unsupportedImageFormat: return NSLocalizedString("Unsupported image format.", comment: "")
        case .unsupportedItem: return NSLocalizedString("Unsupported clipboard item.", comment: "")
        case .noItem: return NSLocalizedString("No clipboard item.", comment: "")
        case .duplicateItem: return NSLocalizedString("Duplicate item.", comment: "")
        }
    }
}

private class PersistentContainer: RSTPersistentContainer
{
    override class func defaultDirectoryURL() -> URL
    {
        // Unsigned builds have no App Group entitlement, so there is no shared container to use.
        guard
            let appGroup = Bundle.main.appGroups.first,
            let sharedDirectoryURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        else { return super.defaultDirectoryURL() }

        let databaseDirectoryURL = sharedDirectoryURL.appendingPathComponent("Database")
        try? FileManager.default.createDirectory(at: databaseDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        
        print("Database URL:", databaseDirectoryURL)
        return databaseDirectoryURL
    }
}

public class DatabaseManager
{
    public static let shared = DatabaseManager()
    
    public let persistentContainer: RSTPersistentContainer = PersistentContainer(name: "Model", bundle: Bundle(for: DatabaseManager.self))
    
    public private(set) var isStarted = false
    
    private var prepareCompletionHandlers = [(Result<Void, Error>) -> Void]()
    private let dispatchQueue = DispatchQueue(label: "com.rileytestut.Clip.DatabaseManager")
    
    private var previousHistoryToken: NSPersistentHistoryToken? {
        set {
            guard let value = newValue else {
                UserDefaults.shared.previousHistoryToken = nil
                return
            }
            
            let data = try? NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true)
            UserDefaults.shared.previousHistoryToken = data
        }
        get {
            guard let data = UserDefaults.shared.previousHistoryToken else { return nil }
            
            let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data)
            return token
        }
    }
    
    private init()
    {
    }

    /// Switches the store to an in-memory one before it is loaded, so the
    /// prepare/save path can be exercised deterministically in tests without touching
    /// disk or an App Group. Must be called before `prepare`.
    public func useInMemoryStoreForTesting()
    {
        self.persistentContainer.persistentStoreDescriptions.forEach { $0.type = NSInMemoryStoreType }
    }

    public func prepare(completionHandler: @escaping (Result<Void, Error>) -> Void)
    {
        func finish(_ result: Result<Void, Error>)
        {
            self.dispatchQueue.async {
                switch result
                {
                case .success: self.isStarted = true
                case .failure: break
                }
                
                self.prepareCompletionHandlers.forEach { $0(result) }
                self.prepareCompletionHandlers.removeAll()
            }
        }
        
        self.dispatchQueue.async {
            self.prepareCompletionHandlers.append(completionHandler)
            guard self.prepareCompletionHandlers.count == 1 else { return }
            
            guard !self.isStarted else { return finish(.success(())) }
            
            self.persistentContainer.persistentStoreDescriptions.first?.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            
            self.persistentContainer.loadPersistentStores { (description, error) in
                let result = Result(description, error).map { _ in () }
                finish(result)
                
                self.purge()
            }
        }
    }
    
    /// Whether a clipping was saved after the given date.
    ///
    /// The app and the notification service extension share this store, so the app can
    /// tell whether the extension managed to save a copy.
    public func hasItemSaved(after date: Date, completionHandler: @escaping (Bool) -> Void)
    {
        self.persistentContainer.performBackgroundTask { (context) in
            let fetchRequest = PasteboardItem.fetchRequest() as NSFetchRequest<PasteboardItem>
            fetchRequest.predicate = NSPredicate(format: "date > %@", date as NSDate)
            fetchRequest.fetchLimit = 1

            do
            {
                let count = try context.count(for: fetchRequest)
                completionHandler(count > 0)
            }
            catch
            {
                completionHandler(false)
            }
        }
    }

    public func refresh()
    {
        DatabaseManager.shared.persistentContainer.performBackgroundTask { (context) in
            let fetchRequest = NSPersistentHistoryChangeRequest.fetchHistory(after: self.previousHistoryToken)
            
            do
            {
                guard
                    let result = try context.execute(fetchRequest) as? NSPersistentHistoryResult,
                    let transactions = result.result as? [NSPersistentHistoryTransaction]
                else { return }
                
                DispatchQueue.main.async {
                    
                    self.persistentContainer.viewContext.undoManager?.disableUndoRegistration()
                    defer { self.persistentContainer.viewContext.undoManager?.enableUndoRegistration() }
                    
                    for transaction in transactions
                    {
                        self.persistentContainer.viewContext.mergeChanges(fromContextDidSave: transaction.objectIDNotification())
                    }
                    
                    if let token = transactions.last?.token
                    {
                        self.previousHistoryToken = token
                    }
                }
            }
            catch let error as CocoaError where error.code.rawValue == NSPersistentHistoryTokenExpiredError
            {
                self.previousHistoryToken = nil
                self.refresh()
            }
            catch
            {
                print("Failed to fetch change history.", error)
            }
        }
    }
    
    public func purge()
    {
        // In-memory contexts don't support history tracking.
        guard let description = DatabaseManager.shared.persistentContainer.persistentStoreDescriptions.first, description.type != NSInMemoryStoreType else { return }
        
        DatabaseManager.shared.persistentContainer.performBackgroundTask { (context) in
            if let token = self.previousHistoryToken
            {
                let deleteHistoryRequest = NSPersistentHistoryChangeRequest.deleteHistory(before: token)
                
                do { try context.execute(deleteHistoryRequest) }
                catch { print("Failed to delete persistent distory.", error) }
            }
            
            do
            {
                let historyFetchRequest = PasteboardItem.historyFetchRequest() as! NSFetchRequest<NSManagedObjectID>
                historyFetchRequest.resultType = .managedObjectIDResultType

                let protectedFetchRequest = PasteboardItem.protectedFetchRequest() as! NSFetchRequest<NSManagedObjectID>
                protectedFetchRequest.resultType = .managedObjectIDResultType

                let objectIDs = try context.fetch(historyFetchRequest) + context.fetch(protectedFetchRequest)

                let deletionFetchRequest = PasteboardItem.fetchRequest() as NSFetchRequest<NSFetchRequestResult>
                deletionFetchRequest.predicate = NSPredicate(format: "NOT (SELF IN %@)", objectIDs)
                
                let batchDeleteRequest = NSBatchDeleteRequest(fetchRequest: deletionFetchRequest)
                batchDeleteRequest.resultType = .resultTypeObjectIDs
                
                guard
                    let result = try context.execute(batchDeleteRequest) as? NSBatchDeleteResult,
                    let deletedObjectIDs = result.result as? [NSManagedObjectID]
                else { return }
                
                let changes = [NSDeletedObjectsKey: deletedObjectIDs]
                
                DispatchQueue.main.async {
                    NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [DatabaseManager.shared.persistentContainer.viewContext])
                }
            }
            catch
            {
                print("Failed to delete pasteboard items.", error)
            }
        }
    }
}

public extension DatabaseManager
{
    func savePasteboard(location: CLLocation?, completionHandler: @escaping (Result<Void, Error>) -> Void)
    {
        do
        {
            guard !UIPasteboard.general.hasColors else {
                throw PasteboardError.unsupportedItem // Accessing UIPasteboard.items causes crash as of iOS 12.3 if it contains a UIColor.
            }
            
            print("Did update pasteboard!")
            
            guard let itemProvider = UIPasteboard.general.itemProviders.first else { throw PasteboardError.noItem }
            guard !itemProvider.registeredTypeIdentifiers.contains(UTI.clipping) else { throw PasteboardError.duplicateItem } // Ignore copies that we made from the app.
            
            let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
            self.savePasteboard(in: context, location: location, representationProvider: { (completionHandler) in
                PasteboardItemRepresentation.representations(for: itemProvider, in: context, completionHandler: completionHandler)
            }, completionHandler: completionHandler)
        }
        catch
        {
            completionHandler(.failure(error))
        }
    }
    
    /// Saves a snapshot read directly from the pasteboard daemon.
    ///
    /// `snapshot` contains one dictionary per pasteboard item, mapping UTI to data.
    func savePasteboard(snapshot: [[String: Data]], location: CLLocation?, completionHandler: @escaping (Result<Void, Error>) -> Void)
    {
        // Ignore copies that we made from the app.
        guard !snapshot.contains(where: { $0.keys.contains(UTI.clipping) }) else {
            completionHandler(.failure(PasteboardError.duplicateItem))
            return
        }
        
        guard let itemSnapshot = snapshot.first else {
            completionHandler(.failure(PasteboardError.noItem))
            return
        }
        
        print("Did read pasteboard from daemon!")
        
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        self.savePasteboard(in: context, location: location, representationProvider: { (completionHandler) in
            PasteboardItemRepresentation.representations(for: itemSnapshot, in: context, completionHandler: completionHandler)
        }, completionHandler: completionHandler)
    }
}

private extension DatabaseManager
{
    func savePasteboard(in context: NSManagedObjectContext, location: CLLocation?, representationProvider: @escaping (@escaping ([PasteboardItemRepresentation]) -> Void) -> Void, completionHandler: @escaping (Result<Void, Error>) -> Void)
    {
        representationProvider { (representations) in
            do
            {
                guard let pasteboardItem = PasteboardItem(representations: representations, context: context) else { throw PasteboardError.noItem }
                pasteboardItem.location = location
                
                let fetchRequest = PasteboardItem.fetchRequest() as NSFetchRequest<PasteboardItem>
                fetchRequest.predicate = NSPredicate(format: "%K == NO AND trashedDate == nil", #keyPath(PasteboardItem.isMarkedForDeletion))
                fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \PasteboardItem.date, ascending: false)]
                fetchRequest.relationshipKeyPathsForPrefetching = ["representations"]
                fetchRequest.includesPendingChanges = false
                fetchRequest.fetchLimit = 1
                
                if let previousItem = try context.fetch(fetchRequest).first
                {
                    let representations = pasteboardItem.representations.reduce(into: [:], { ($0[$1.type] = $1.value as? NSObject) })
                    let previousRepresentations = previousItem.representations.reduce(into: [:], { ($0[$1.type] = $1.value as? NSObject) })

                    guard representations != previousRepresentations else {
                        throw PasteboardError.duplicateItem
                    }
                }
                
                guard let _ = pasteboardItem.preferredRepresentation else { throw PasteboardError.unsupportedItem }
                
                context.transactionAuthor = Bundle.main.bundleIdentifier
                try context.save()
                
                let center = CFNotificationCenterGetDarwinNotifyCenter()
                CFNotificationCenterPostNotification(center, .didChangePasteboard, nil, nil, true)
                
                DispatchQueue.main.async {
                    completionHandler(.success(()))
                }
            }
            catch
            {
                DispatchQueue.main.async {
                    print("Failed to handle pasteboard item.", error)
                    completionHandler(.failure(error))
                }
            }
        }
    }
}
