//
//  ItemListViewModel.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 11/9/21.
//  Copyright © 2021 Tortuga Power. All rights reserved.
//

import BookPlayerKit
import Combine
import Foundation
import MediaPlayer
import Themeable

class ItemListViewModel: BaseViewModel<ItemListCoordinator> {
  let folder: Folder?
  let library: Library
  let playerManager: PlayerManagerProtocol
  let libraryService: LibraryServiceProtocol
  var offset = 0

  public private(set) var defaultArtwork: Data?
  private var themeAccent: UIColor
  public private(set) var itemsUpdates = PassthroughSubject<[SimpleLibraryItem], Never>()
  public private(set) var itemProgressUpdates = PassthroughSubject<IndexPath, Never>()
  public private(set) var items = [SimpleLibraryItem]()
  private var bookSubscription: AnyCancellable?
  private var bookProgressSubscription: AnyCancellable?
  private var containingFolder: Folder?

  public var maxItems: Int {
    return self.folder?.items?.count ?? self.library.items?.count ?? 0
  }

  init(folder: Folder?,
       library: Library,
       playerManager: PlayerManagerProtocol,
       libraryService: LibraryServiceProtocol,
       themeAccent: UIColor) {
    self.folder = folder
    self.library = library
    self.playerManager = playerManager
    self.libraryService = libraryService
    self.themeAccent = themeAccent
    self.defaultArtwork = ArtworkService.generateDefaultArtwork(from: themeAccent)?.pngData()
    super.init()

    self.bindBookObserver()
  }

  func getEmptyStateImageName() -> String {
    return self.coordinator is LibraryListCoordinator
    ? "emptyLibrary"
    : "emptyPlaylist"
  }

  func getNavigationTitle() -> String {
    return self.folder?.title ?? "library_title".localized
  }

  func bindBookObserver() {
    self.bookSubscription = self.playerManager.currentBookPublisher().sink { [weak self] book in
      guard let self = self else { return }

      self.bookProgressSubscription?.cancel()
      self.containingFolder = nil

      guard let book = book else {
        self.clearPlaybackState()
        return
      }

      // Get folder reference for progress calculation
      if let item = self.items.first(where: { book.relativePath.contains($0.relativePath) && $0.type == .folder }) {
        self.containingFolder = book.getFolder(matching: item.relativePath)
      }

      self.bindBookProgressObserver(book)
    }
  }

  func bindBookProgressObserver(_ book: Book) {
    self.bookProgressSubscription?.cancel()

    self.bookProgressSubscription = book.publisher(for: \.percentCompleted)
      .combineLatest(book.publisher(for: \.relativePath))
      .removeDuplicates(by: { $0.0 == $1.0 })
      .sink(receiveValue: { [weak self] (percentCompleted, relativePath) in
        guard let self = self,
              let relativePath = relativePath,
              let index = self.items.firstIndex(where: { relativePath.contains($0.relativePath) }) else { return }

        let currentItem = self.items[index]

        var progress: Double?

        switch currentItem.type {
        case .book:
          progress = percentCompleted / 100
        case .folder:
          progress = self.containingFolder?.progressPercentage
        }

        let updatedItem = SimpleLibraryItem(from: currentItem, progress: progress, playbackState: .playing)

        self.items[index] = updatedItem

        let indexModified = IndexPath(row: index, section: Section.data.rawValue)
        self.itemProgressUpdates.send(indexModified)
      })
  }

  func clearPlaybackState() {
    self.items = self.items.map({ SimpleLibraryItem(from: $0, playbackState: .stopped) })
    self.itemsUpdates.send(self.items)
  }

  func loadInitialItems(pageSize: Int = 13) -> [SimpleLibraryItem] {
    guard let fetchedItems = self.libraryService.fetchContents(at: self.folder?.relativePath,
                                                            limit: pageSize,
                                                            offset: 0) else {
      return []
    }

    let displayItems = fetchedItems.map({ SimpleLibraryItem(
                                          from: $0,
                                          themeAccent: self.themeAccent,
                                          playbackState: self.getPlaybackState(for: $0)) })
    self.offset = displayItems.count
    self.items = displayItems

    return displayItems
  }

  func loadNextItems(pageSize: Int = 13) {
    guard self.offset < self.maxItems else { return }

    guard let fetchedItems = self.libraryService.fetchContents(at: self.folder?.relativePath,
                                                            limit: pageSize,
                                                            offset: self.offset),
          !fetchedItems.isEmpty else {
      return
    }

    let displayItems = fetchedItems.map({ SimpleLibraryItem(
                                          from: $0,
                                          themeAccent: self.themeAccent,
                                          playbackState: self.getPlaybackState(for: $0)) })
    self.offset += displayItems.count

    self.items += displayItems
    self.itemsUpdates.send(self.items)
  }

  func loadAllItemsIfNeeded() {
    guard self.offset < self.maxItems else { return }

    guard let fetchedItems = self.libraryService.fetchContents(at: self.folder?.relativePath,
                                                            limit: self.maxItems,
                                                            offset: 0),
          !fetchedItems.isEmpty else {
      return
    }

    let displayItems = fetchedItems.map({ SimpleLibraryItem(
                                          from: $0,
                                          themeAccent: self.themeAccent,
                                          playbackState: self.getPlaybackState(for: $0)) })
    self.offset = displayItems.count

    self.items = displayItems
    self.itemsUpdates.send(self.items)
  }

  func getItem(of type: SimpleItemType, after currentIndex: Int) -> Int? {
    guard let (index, _) = (self.items.enumerated().first { (index, item) in
      guard index > currentIndex else { return false }

      return item.type == type
    }) else { return nil }

    return index
  }

  func getItem(of type: SimpleItemType, before currentIndex: Int) -> Int? {
    guard let (index, _) = (self.items.enumerated().reversed().first { (index, item) in
      guard index < currentIndex else { return false }

      return item.type == type
    }) else { return nil }

    return index
  }

  func playNextBook(after item: SimpleLibraryItem) {
    guard let libraryItem = self.libraryService.getItem(with: item.relativePath) else {
      return
    }

    var bookToPlay: Book?

    defer {
      if let book = bookToPlay {
        self.coordinator.loadPlayer(book)
      }
    }

    guard let folder = libraryItem as? Folder else {
      bookToPlay = libraryItem.getBookToPlay()
      return
    }

    // Special treatment for folders
    guard
      let bookPlaying = self.playerManager.currentBook,
      let currentFolder = bookPlaying.folder,
      currentFolder == folder else {
        // restart the selected folder if current playing book has no relation to it
        if libraryItem.isFinished {
          self.libraryService.jumpToStart(relativePath: libraryItem.relativePath)
        }

        bookToPlay = libraryItem.getBookToPlay()
        return
      }

    // override next book with the one already playing
    bookToPlay = bookPlaying
  }

  func reloadItems(pageSizePadding: Int = 0) {
    let pageSize = self.items.count + pageSizePadding
    let loadedItems = self.loadInitialItems(pageSize: pageSize)
    self.itemsUpdates.send(loadedItems)
  }

  func checkSystemModeTheme() {
    ThemeManager.shared.checkSystemMode()
  }

  func getPlaybackState(for item: LibraryItem) -> PlaybackState {
    // TODO: refactor PlayerManager to stop using backed coredata objects
    guard let book = self.playerManager.currentBook, !book.isFault else {
      return .stopped
    }

    return book.relativePath.contains(item.relativePath) ? .playing : .stopped
  }

  func showItemContents(_ item: SimpleLibraryItem) {
    guard let libraryItem = self.libraryService.getItem(with: item.relativePath) else {
      return
    }

    self.coordinator.showItemContents(libraryItem)
  }

  func importIntoNewFolder(with title: String, items: [LibraryItem]? = nil) {
    do {
      let folder = try self.libraryService.createFolder(with: title, inside: self.folder?.relativePath, at: nil)
      if let items = items {
        try self.libraryService.moveItems(items, into: folder, at: nil)
      }
    } catch {
      self.coordinator.showAlert("error_title".localized, message: error.localizedDescription)
    }

    self.coordinator.reloadItemsWithPadding(padding: 1)
  }

  func importIntoFolder(_ folder: SimpleLibraryItem, items: [LibraryItem]) {
    guard let storedFolder = self.libraryService.getItem(with: folder.relativePath) as? Folder else { return }

    let fetchedItems = items.compactMap({ self.libraryService.getItem(with: $0.relativePath )})

    do {
      try self.libraryService.moveItems(fetchedItems, into: storedFolder, at: nil)
    } catch {
      self.coordinator.showAlert("error_title".localized, message: error.localizedDescription)
    }

    self.coordinator.reloadItemsWithPadding()
  }

  func createFolder(with title: String, items: [SimpleLibraryItem]? = nil) {
    do {
      let folder = try self.libraryService.createFolder(with: title, inside: self.folder?.relativePath, at: nil)
      if let fetchedItems = items?.compactMap({ self.libraryService.getItem(with: $0.relativePath )}) {
        try self.libraryService.moveItems(fetchedItems, into: folder, at: nil)
      }
    } catch {
      self.coordinator.showAlert("error_title".localized, message: error.localizedDescription)
    }

    self.coordinator.reloadItemsWithPadding(padding: 1)
  }

  func handleMoveIntoLibrary(items: [SimpleLibraryItem]) {
    let selectedItems = items.compactMap({ self.libraryService.getItem(with: $0.relativePath )})

    do {
      try self.libraryService.moveItems(selectedItems, into: self.library, moveFiles: true, at: nil)
    } catch {
      self.coordinator.showAlert("error_title".localized, message: error.localizedDescription)
    }

    self.coordinator.reloadItemsWithPadding(padding: selectedItems.count)
  }

  func handleMoveIntoFolder(_ folder: SimpleLibraryItem, items: [SimpleLibraryItem]) {
    ArtworkService.removeCache(for: folder.relativePath)

    guard let storedFolder = self.libraryService.getItem(with: folder.relativePath) as? Folder else { return }

    let fetchedItems = items.compactMap({ self.libraryService.getItem(with: $0.relativePath )})

    do {
      try self.libraryService.moveItems(fetchedItems, into: storedFolder, at: nil)
    } catch {
      self.coordinator.showAlert("error_title".localized, message: error.localizedDescription)
    }

    self.coordinator.reloadItemsWithPadding()
  }

  func handleDelete(items: [SimpleLibraryItem], mode: DeleteMode) {
    let selectedItems = items.compactMap({ self.libraryService.getItem(with: $0.relativePath )})

    do {
      try self.libraryService.delete(selectedItems, library: self.library, mode: mode)
    } catch {
      self.coordinator.showAlert("error_title".localized, message: error.localizedDescription)
    }

    self.coordinator.reloadItemsWithPadding()
  }

  func handleOperationCompletion(_ files: [URL]) {
    let processedItems = self.libraryService.insertItems(from: files, into: nil, library: self.library, processedItems: [])

    do {
      if let folder = self.folder {
        try self.libraryService.moveItems(processedItems, into: folder, at: nil)
      } else {
        try self.libraryService.moveItems(processedItems, into: self.library, moveFiles: false, at: nil)
      }

    } catch {
      self.coordinator.showAlert("error_title".localized, message: error.localizedDescription)
      return
    }

    self.coordinator.reloadItemsWithPadding(padding: processedItems.count)

    var availableFolders = [SimpleLibraryItem]()

    if let existingFolders = (self.libraryService.fetchContents(at: self.folder?.relativePath, limit: nil, offset: nil)?
                                .compactMap({ $0 as? Folder })) {
      for folder in existingFolders {
        if processedItems.contains(where: { $0.relativePath == folder.relativePath }) { continue }

        availableFolders.append(SimpleLibraryItem(from: folder, themeAccent: self.themeAccent))
      }
    }

    if processedItems.count > 1 {
      self.coordinator.showOperationCompletedAlert(with: processedItems, availableFolders: availableFolders)
    }
  }

  func handleInsertionIntoLibrary(_ items: [LibraryItem]) {
    do {
      try self.libraryService.moveItems(items, into: self.library, moveFiles: true, at: nil)
    } catch {
      self.coordinator.showAlert("error_title".localized, message: error.localizedDescription)
    }

    self.coordinator.reloadItemsWithPadding(padding: items.count)
  }

  func reorder(item: SimpleLibraryItem, sourceIndexPath: IndexPath, destinationIndexPath: IndexPath) {
    guard let storedItem = self.libraryService.getItem(with: item.relativePath) else { return }

    if let folder = self.folder {
      ArtworkService.removeCache(for: folder.relativePath)
      folder.removeFromItems(at: sourceIndexPath.row)
      folder.insertIntoItems(storedItem, at: destinationIndexPath.row)
      folder.rebuildOrderRank()
    } else {
      self.library.removeFromItems(at: sourceIndexPath.row)
      self.library.insertIntoItems(storedItem, at: destinationIndexPath.row)
      self.library.rebuildOrderRank()
    }

    self.libraryService.saveContext()

    _ = self.loadInitialItems(pageSize: self.items.count)
  }

  func updateDefaultArtwork(for theme: SimpleTheme) {
    self.defaultArtwork = ArtworkService.generateDefaultArtwork(from: theme.linkColor)?.pngData()
  }

  func showMiniPlayer(_ flag: Bool) {
    if let mainCoordinator = self.coordinator?.getMainCoordinator() {
      mainCoordinator.showMiniPlayer(flag)
    }
  }

  func showSettings() {
    self.coordinator.showSettings()
  }

  func showAddActions() {
    self.coordinator.showAddActions()
  }

  func notifyPendingFiles() {
    let documentsFolder = DataManager.getDocumentsFolderURL()

    // Get reference of all the files located inside the Documents folder
    guard let urls = try? FileManager.default.contentsOfDirectory(at: documentsFolder, includingPropertiesForKeys: nil, options: .skipsSubdirectoryDescendants) else {
      return
    }

    // Filter out Processed and Inbox folders from file URLs.
    let filteredUrls = urls.filter {
      $0.lastPathComponent != DataManager.processedFolderName
      && $0.lastPathComponent != DataManager.inboxFolderName
    }

    guard !filteredUrls.isEmpty else { return }

    self.handleNewFiles(filteredUrls)
  }

  func handleNewFiles(_ urls: [URL]) {
    self.coordinator.processFiles(urls: urls)
  }

  func showSortOptions() {
    self.coordinator.showSortOptions()
  }

  func showMoveOptions(selectedItems: [SimpleLibraryItem]) {
    var availableFolders = [SimpleLibraryItem]()

    if let existingFolders = (self.libraryService.fetchContents(at: self.folder?.relativePath, limit: nil, offset: nil)?
                                .compactMap({ $0 as? Folder })) {
      for folder in existingFolders {
        if selectedItems.contains(where: { $0.relativePath == folder.relativePath }) { continue }

        availableFolders.append(SimpleLibraryItem(from: folder, themeAccent: self.themeAccent))
      }
    }

    self.coordinator.showMoveOptions(selectedItems: selectedItems, availableFolders: availableFolders)
  }

  func showDeleteOptions(selectedItems: [SimpleLibraryItem]) {
    self.coordinator.showDeleteAlert(selectedItems: selectedItems)
  }

  func showMoreOptions(selectedItems: [SimpleLibraryItem]) {
    var availableFolders = [SimpleLibraryItem]()

    if let existingFolders = (self.libraryService.fetchContents(at: self.folder?.relativePath, limit: nil, offset: nil)?
                                .compactMap({ $0 as? Folder })) {
      for folder in existingFolders {
        if selectedItems.contains(where: { $0.relativePath == folder.relativePath }) { continue }

        availableFolders.append(SimpleLibraryItem(from: folder, themeAccent: self.themeAccent))
      }
    }

    self.coordinator.showMoreOptionsAlert(selectedItems: selectedItems, availableFolders: availableFolders)
  }

  func handleSort(by option: PlayListSortOrder) {
    let itemsToSortOptional: NSOrderedSet?

    if let folder = self.folder {
      itemsToSortOptional = folder.items
    } else {
      itemsToSortOptional = self.library.items
    }

    guard let itemsToSort = itemsToSortOptional,
          itemsToSort.count > 0 else { return }

    let sortedItems = BookSortService.sort(itemsToSort, by: option)

    if let folder = folder {
      folder.items = sortedItems
      folder.rebuildOrderRank()
    } else {
      self.library.items = sortedItems
      self.library.rebuildOrderRank()
    }

    self.libraryService.saveContext()

    self.reloadItems()
  }

  func handleRename(item: SimpleLibraryItem, with newTitle: String) {
    self.libraryService.renameItem(at: item.relativePath, with: newTitle)

    self.coordinator.reloadItemsWithPadding()
  }

  func handleResetPlaybackPosition(for items: [SimpleLibraryItem]) {
    items.forEach({ self.libraryService.jumpToStart(relativePath: $0.relativePath) })

    self.coordinator.reloadItemsWithPadding()
  }

  func handleMarkAsFinished(for items: [SimpleLibraryItem], flag: Bool) {
    items.forEach({ self.libraryService.markAsFinished(flag: flag, relativePath: $0.relativePath) })

    self.coordinator.reloadItemsWithPadding()
  }

  func handleDownload(_ url: URL) {
    NetworkService.shared.download(from: url) { response in
      NotificationCenter.default.post(name: .downloadEnd, object: self)

      if response.error != nil,
         let error = response.error {
        self.coordinator.showAlert("network_error_title".localized, message: error.localizedDescription)
      }

      if let response = response.response, response.statusCode >= 300 {
        self.coordinator.showAlert("network_error_title".localized, message: "Code \(response.statusCode)")
      }
    }
  }

  func importData(from item: ImportableItem) {
    let filename = item.suggestedName ?? "\(Date().timeIntervalSince1970).\(item.fileExtension)"

    let destinationURL = DataManager.getDocumentsFolderURL()
      .appendingPathComponent(filename)

    do {
      try item.data.write(to: destinationURL)
    } catch {
      print("Fail to move dropped file to the Documents directory: \(error.localizedDescription)")
    }
  }
}
