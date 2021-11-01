//
//  DataManager.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 2/3/19.
//  Copyright © 2019 Tortuga Power. All rights reserved.
//

import CoreData
import Foundation

public class DataManager {
  public static let processedFolderName = "Processed"
  public static let inboxFolderName = "Inbox"
  public static var loadingDataError: Error?
  private let coreDataStack: CoreDataStack

  public init(coreDataStack: CoreDataStack) {
    self.coreDataStack = coreDataStack
  }
    // MARK: - Folder URLs

    public class func getDocumentsFolderURL() -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    public class func getProcessedFolderURL() -> URL {
        let documentsURL = self.getDocumentsFolderURL()

        let processedFolderURL = documentsURL.appendingPathComponent(self.processedFolderName)

        if !FileManager.default.fileExists(atPath: processedFolderURL.path) {
            do {
                try FileManager.default.createDirectory(at: processedFolderURL, withIntermediateDirectories: true, attributes: nil)
            } catch {
                fatalError("Couldn't create Processed folder")
            }
        }

        return processedFolderURL
    }

    public class func getInboxFolderURL() -> URL {
        let documentsURL = self.getDocumentsFolderURL()

        let inboxFolderURL = documentsURL.appendingPathComponent(self.inboxFolderName)

        if !FileManager.default.fileExists(atPath: inboxFolderURL.path) {
            do {
                try FileManager.default.createDirectory(at: inboxFolderURL, withIntermediateDirectories: true, attributes: nil)
            } catch {
                fatalError("Couldn't create Inbox folder")
            }
        }

        return inboxFolderURL
    }

  public class func sizeOfItem(at url: URL) -> String {
    var folderSize: Int64 = 0

    let enumerator = FileManager.default.enumerator(
      at: url,
      includingPropertiesForKeys: [],
      options: [.skipsHiddenFiles], errorHandler: { (url, error) -> Bool in
        print("directoryEnumerator error at \(url): ", error)
        return true
      })!

    for case let fileURL as URL in enumerator {
      guard let fileAttributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else { continue }
      folderSize += fileAttributes[FileAttributeKey.size] as? Int64 ?? 0
    }

    return ByteCountFormatter.string(fromByteCount: folderSize, countStyle: ByteCountFormatter.CountStyle.file)
  }

  public func getContext() -> NSManagedObjectContext {
    return self.coreDataStack.managedContext
  }

  public func saveContext() {
    self.coreDataStack.saveContext()
  }

  public func getBackgroundContext() -> NSManagedObjectContext {
    return self.coreDataStack.getBackgroundContext()
  }

  // MARK: - Models handler

  /**
   Gets the library for the App. There should be only one Library object at all times
   */
  public func getLibrary() throws -> Library? {
    let context = self.getContext()
    let fetch: NSFetchRequest<Library> = Library.fetchRequest()
    fetch.returnsObjectsAsFaults = false
    return try context.fetch(fetch).first
  }

  public func getLibraryLastBook() throws -> Book? {
    let context = self.getContext()
    let fetchRequest: NSFetchRequest<NSDictionary> = NSFetchRequest<NSDictionary>(entityName: "Library")
    fetchRequest.propertiesToFetch = ["lastPlayedBook"]
    fetchRequest.resultType = .dictionaryResultType

    guard let dict = try context.fetch(fetchRequest).first as? [String: NSManagedObjectID],
          let lastPlayedBookId = dict["lastPlayedBook"] else {
      return nil
    }

    return try? context.existingObject(with: lastPlayedBookId) as? Book
  }

  public func getLibraryCurrentTheme() throws -> Theme? {
    let context = self.getContext()
    let fetchRequest: NSFetchRequest<NSDictionary> = NSFetchRequest<NSDictionary>(entityName: "Library")
    fetchRequest.propertiesToFetch = ["currentTheme"]
    fetchRequest.resultType = .dictionaryResultType

    guard let dict = try context.fetch(fetchRequest).first as? [String: NSManagedObjectID],
          let themeId = dict["currentTheme"] else {
      return self.getTheme(with: "Default / Dark")
    }

    return try? context.existingObject(with: themeId) as? Theme
  }

  public func createLibrary() -> Library {
    let context = self.getContext()
    let library = Library.create(in: context)
    self.saveContext()
    return library
  }

  public func getBooks() -> [Book]? {
    let fetch: NSFetchRequest<Book> = Book.fetchRequest()
    let context = self.coreDataStack.managedContext

    return try? context.fetch(fetch)
  }

  public func getTheme(with title: String) -> Theme? {
    let fetchRequest: NSFetchRequest<Theme> = Theme.fetchRequest()
    fetchRequest.predicate = NSPredicate(format: "title == %@", title)
    fetchRequest.fetchLimit = 1

    return try? self.getContext().fetch(fetchRequest).first
  }

  /**
   Gets a stored book from an identifier.
   */
  public func getBook(with identifier: String, from library: Library) -> Book? {
    guard let item = library.getItem(with: identifier)
    else {
      return nil
    }

    return item as? Book
  }

  public func findBooks(containing fileURL: URL) -> [Book]? {
    let fetch: NSFetchRequest<Book> = Book.fetchRequest()
    fetch.predicate = NSPredicate(format: "relativePath ENDSWITH[C] %@", fileURL.lastPathComponent)
    let context = self.coreDataStack.managedContext

    return try? context.fetch(fetch)
  }

  public func getOrderedBooks(limit: Int? = nil) -> [Book]? {
    let fetch: NSFetchRequest<Book> = Book.fetchRequest()
    fetch.predicate = NSPredicate(format: "lastPlayDate != nil")

    if let limit = limit {
      fetch.fetchLimit = limit
    }

    let sort = NSSortDescriptor(key: #keyPath(Book.lastPlayDate), ascending: false)
    fetch.sortDescriptors = [sort]

    let context = self.coreDataStack.managedContext

    return try? context.fetch(fetch)
  }

  public func createFolder(title: String) -> Folder {
    return Folder(title: title, context: self.getContext())
  }

  public func removeFolderIfNeeded(_ fileURL: URL) throws {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

    // Delete folder if it belongs to an orphaned folder
    if let existingFolder = self.findFolder(with: fileURL)?.first {
      if existingFolder.getLibrary() == nil {
        // Delete folder if it doesn't belong to active folder
        try FileManager.default.removeItem(at: fileURL)
        self.delete(existingFolder)
      }
    } else {
      // Delete folder if it doesn't belong to active folder
      try FileManager.default.removeItem(at: fileURL)
    }
  }

  public func createFolder(with title: String, in folder: Folder?, library: Library, at index: Int? = nil) throws -> Folder {
    let newFolder: Folder
    let processedFolder = DataManager.getProcessedFolderURL()

    if let folder = folder {
      let destinationURL = processedFolder.appendingPathComponent(folder.relativePath).appendingPathComponent(title)

      try? removeFolderIfNeeded(destinationURL)

      try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false, attributes: nil)

      newFolder = Folder(title: title, context: self.getContext())
      folder.insert(item: newFolder, at: index)
    } else {
      let destinationURL = processedFolder.appendingPathComponent(title)

      try? removeFolderIfNeeded(destinationURL)

      try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false, attributes: nil)

      newFolder = Folder(title: title, context: self.getContext())
      library.insert(item: newFolder, at: index)
    }

    self.saveContext()

    return newFolder
  }

  public func findFolder(with fileURL: URL) -> [Folder]? {
    let fetch: NSFetchRequest<Folder> = Folder.fetchRequest()

    fetch.predicate = NSPredicate(format: "relativePath == %@", String(fileURL.relativePath(to: DataManager.getProcessedFolderURL()).dropFirst()))
    let context = self.coreDataStack.managedContext

    return try? context.fetch(fetch)
  }

  public func insert(_ folder: Folder, into library: Library, at index: Int? = nil) {
    library.insert(item: folder, at: index)
    self.saveContext()
  }

  public func insert(_ item: LibraryItem, into folder: Folder, at index: Int? = nil) {
    folder.insert(item: item, at: index)
    self.saveContext()
  }

  public func delete(_ item: NSManagedObject) {
    self.coreDataStack.managedContext.delete(item)
    self.saveContext()
  }

  public func jumpToStart(_ item: LibraryItem) {
    item.jumpToStart()
    item.markAsFinished(false)
    self.saveContext()
  }

  public func mark(_ item: LibraryItem, asFinished: Bool) {
    item.markAsFinished(asFinished)
    self.saveContext()
  }

  // MARK: - TimeRecord

  public func getPlaybackRecord() -> PlaybackRecord {
    let calendar = Calendar.current

    let today = Date()
    let dateFrom = calendar.startOfDay(for: today)
    let dateTo = calendar.date(byAdding: .day, value: 1, to: dateFrom)!

    // Set predicate as date being today's date
    let fromPredicate = NSPredicate(format: "date >= %@", dateFrom as NSDate)
    let toPredicate = NSPredicate(format: "date < %@", dateTo as NSDate)
    let datePredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [fromPredicate, toPredicate])

    let context = self.coreDataStack.managedContext
    let fetch: NSFetchRequest<PlaybackRecord> = PlaybackRecord.fetchRequest()
    fetch.predicate = datePredicate

    let record = try? context.fetch(fetch).first

    return record ?? PlaybackRecord.create(in: context)
  }

  public func getPlaybackRecords(from startDate: Date, to endDate: Date) -> [PlaybackRecord]? {
    let fromPredicate = NSPredicate(format: "date >= %@", startDate as NSDate)
    let toPredicate = NSPredicate(format: "date < %@", endDate as NSDate)
    let datePredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [fromPredicate, toPredicate])

    let fetch: NSFetchRequest<PlaybackRecord> = PlaybackRecord.fetchRequest()
    fetch.predicate = datePredicate
    let context = self.coreDataStack.managedContext

    return try? context.fetch(fetch)
  }

  public func recordTime(_ playbackRecord: PlaybackRecord) {
    playbackRecord.time += 1
    self.saveContext()
  }
}