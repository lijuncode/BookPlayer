//
//  ItemListCoordinator.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 9/9/21.
//  Copyright © 2021 Tortuga Power. All rights reserved.
//

import BookPlayerKit
import Combine
import UIKit

public typealias Transition<T> = ((T) -> Void)
enum ItemListActionRoutes {
  case importOptions
  case importLocalFiles
  case importIntoNewFolder(_ title: String, items: [LibraryItem]?)
  case importIntoFolder(_ folder: SimpleLibraryItem, items: [LibraryItem])
  case downloadBook(_ url: URL)
  case createFolder(_ title: String, items: [SimpleLibraryItem]?)
  case moveIntoLibrary(items: [SimpleLibraryItem])
  case moveIntoFolder(_ folder: SimpleLibraryItem, items: [SimpleLibraryItem])
  case delete(_ items: [SimpleLibraryItem], mode: DeleteMode)
  case rename(_ item: SimpleLibraryItem, newTitle: String)
  case resetPlaybackPosition(_ items: [SimpleLibraryItem])
  case markAsFinished(_ items: [SimpleLibraryItem], flag: Bool)
  case newImportOperation(_ operation: ImportOperation)
  case importOperationFinished(_ urls: [URL])
  case insertIntoLibrary(_ items: [LibraryItem])
  case sortItems(_ option: PlayListSortOrder)
  case reloadItems(_ pageSizePadding: Int)
}

class ItemListCoordinator: Coordinator {
  public var onAction: Transition<ItemListActionRoutes>?
  let playerManager: PlayerManagerProtocol
  let importManager: ImportManager
  let dataManager: DataManager
  let libraryService: LibraryServiceProtocol
  let library: Library

  weak var documentPickerDelegate: UIDocumentPickerDelegate?
  var fileSubscription: AnyCancellable?
  var importOperationSubscription: AnyCancellable?

  init(
    navigationController: UINavigationController,
    library: Library,
    playerManager: PlayerManagerProtocol,
    importManager: ImportManager,
    dataManager: DataManager,
    libraryService: LibraryServiceProtocol
  ) {
    self.library = library
    self.playerManager = playerManager
    self.importManager = importManager
    self.dataManager = dataManager
    self.libraryService = libraryService

    super.init(navigationController: navigationController,
               flowType: .push)

    self.bindImportObserver()
  }

  func bindImportObserver() {
    self.fileSubscription?.cancel()
    self.importOperationSubscription?.cancel()

    self.fileSubscription = self.importManager.observeFiles().sink { [weak self] files in
      guard let self = self,
            !files.isEmpty,
            self.shouldShowImportScreen() else { return }

      self.showImport()
    }

    self.importOperationSubscription = self.importManager.operationPublisher.sink(receiveValue: { [weak self] operation in
      guard let self = self,
            self.shouldHandleImport() else {
        return
      }

      self.onAction?(.newImportOperation(operation))

      operation.completionBlock = {
        DispatchQueue.main.async {
          self.onAction?(.importOperationFinished(operation.processedFiles))
        }
      }

      self.importManager.start(operation)
    })
  }

  func processFiles(urls: [URL]) {
    for url in urls {
      self.importManager.process(url)
    }
  }

  override func start() {
    fatalError("ItemListCoordinator is an abstract class, override this function in the subclass")
  }

  override func getMainCoordinator() -> MainCoordinator? {
    switch self.parentCoordinator {
    case let mainCoordinator as MainCoordinator:
      return mainCoordinator
    case let listCoordinator as ItemListCoordinator:
      return listCoordinator.getMainCoordinator()
    default:
      return nil
    }
  }

  func showItemContents(_ item: LibraryItem) {
    switch item {
    case let folder as Folder:
      self.showFolder(folder)
    case let book as Book:
      self.loadPlayer(book)
    default:
      break
    }
  }

  func showFolder(_ folder: Folder) {
    let child = FolderListCoordinator(navigationController: self.navigationController,
                                      library: self.library,
                                      folder: folder,
                                      playerManager: self.playerManager,
                                      importManager: self.importManager,
                                      dataManager: self.dataManager,
                                      libraryService: self.libraryService)
    self.childCoordinators.append(child)
    child.parentCoordinator = self
    child.start()
  }

  func showPlayer() {
    let playerCoordinator = PlayerCoordinator(
      navigationController: self.navigationController,
      playerManager: self.playerManager,
      libraryService: self.libraryService
    )
    playerCoordinator.parentCoordinator = self
    self.childCoordinators.append(playerCoordinator)
    playerCoordinator.start()
  }

  func loadPlayer(_ book: Book) {
    let fileURL = DataManager.getProcessedFolderURL().appendingPathComponent(book.relativePath)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      self.navigationController.showAlert("file_missing_title".localized, message: "\("file_missing_description".localized)\n\(book.originalFileName ?? "")")
      return
    }

    // Only load if loaded book is a different one
    guard book.relativePath != playerManager.currentBook?.relativePath else {
      self.showPlayer()
      return
    }

    self.playerManager.load(book) { [weak self] loaded in
      guard loaded else { return }

      self?.getMainCoordinator()?.showMiniPlayer(true)
      self?.playerManager.playPause()
    }
    self.showPlayer()
  }

  func loadLastBook(_ book: Book) {
    self.playerManager.load(book) { [weak self] loaded in
      guard loaded else { return }

      self?.getMainCoordinator()?.showMiniPlayer(true)

      if UserDefaults.standard.bool(forKey: Constants.UserActivityPlayback) {
        UserDefaults.standard.removeObject(forKey: Constants.UserActivityPlayback)
        self?.playerManager.play()
      }

      if UserDefaults.standard.bool(forKey: Constants.UserDefaults.showPlayer.rawValue) {
        UserDefaults.standard.removeObject(forKey: Constants.UserDefaults.showPlayer.rawValue)
        self?.showPlayer()
      }
    }
  }

  func showSettings() {
    let settingsCoordinator = SettingsCoordinator(
      libraryService: self.libraryService,
      library: self.library,
      navigationController: AppNavigationController.instantiate(from: .Settings)
    )
    settingsCoordinator.parentCoordinator = self
    settingsCoordinator.presentingViewController = self.presentingViewController
    self.childCoordinators.append(settingsCoordinator)
    settingsCoordinator.start()
  }

  func showImport() {
    let child = ImportCoordinator(
      navigationController: self.navigationController,
      importManager: self.importManager
    )
    self.childCoordinators.append(child)
    child.parentCoordinator = self
    child.presentingViewController = self.presentingViewController
    child.start()
  }

  func shouldShowImportScreen() -> Bool {
    return !self.childCoordinators.contains(where: { $0 is ItemListCoordinator || $0 is ImportCoordinator })
  }

  func shouldHandleImport() -> Bool {
    return !self.childCoordinators.contains(where: { $0 is ItemListCoordinator })
  }

  func showOperationCompletedAlert(with items: [LibraryItem], availableFolders: [SimpleLibraryItem]) {
    let alert = UIAlertController(
      title: String.localizedStringWithFormat("import_alert_title".localized, items.count),
      message: nil,
      preferredStyle: .alert)

    alert.addAction(UIAlertAction(title: "library_title".localized, style: .default, handler: nil))

    alert.addAction(UIAlertAction(title: "new_playlist_button".localized, style: .default) { _ in
      var placeholder = "new_playlist_button".localized

      if let item = items.first {
        placeholder = item.title
      }

      self.showImportIntoNewFolderAlert(placeholder: placeholder, with: items)
    })

    let existingFolderAction = UIAlertAction(title: "existing_playlist_button".localized, style: .default) { _ in
      let vc = ItemSelectionViewController()
      vc.items = availableFolders

      vc.onItemSelected = { selectedFolder in
        self.onAction?(.importIntoFolder(selectedFolder, items: items))
      }

      let nav = AppNavigationController(rootViewController: vc)
      self.navigationController.present(nav, animated: true, completion: nil)
    }

    existingFolderAction.isEnabled = !availableFolders.isEmpty
    alert.addAction(existingFolderAction)

    self.navigationController.present(alert, animated: true, completion: nil)
  }
}

extension ItemListCoordinator {
  func showImportIntoNewFolderAlert(placeholder: String? = nil, with items: [LibraryItem]? = nil) {
    let alert = UIAlertController(title: "create_playlist_title".localized,
                                  message: "create_playlist_description".localized,
                                  preferredStyle: .alert)

    alert.addTextField(configurationHandler: { textfield in
      textfield.text = placeholder ?? "new_playlist_button".localized
    })

    alert.addAction(UIAlertAction(title: "cancel_button".localized, style: .cancel, handler: nil))
    alert.addAction(UIAlertAction(title: "create_button".localized, style: .default, handler: { _ in
      let title = alert.textFields!.first!.text!
      self.onAction?(.importIntoNewFolder(title, items: items))
    }))

    self.navigationController.present(alert, animated: true, completion: nil)
  }

  func showCreateFolderAlert(placeholder: String? = nil, with items: [SimpleLibraryItem]? = nil) {
    let alert = UIAlertController(title: "create_playlist_title".localized,
                                  message: "create_playlist_description".localized,
                                  preferredStyle: .alert)

    alert.addTextField(configurationHandler: { textfield in
      textfield.text = placeholder ?? "new_playlist_button".localized
    })

    alert.addAction(UIAlertAction(title: "cancel_button".localized, style: .cancel, handler: nil))
    alert.addAction(UIAlertAction(title: "create_button".localized, style: .default, handler: { _ in
      let title = alert.textFields!.first!.text!
      self.onAction?(.createFolder(title, items: items))
    }))

    self.navigationController.present(alert, animated: true, completion: nil)
  }

  func showAddActions() {
    let alertController = UIAlertController(title: nil,
                                            message: "import_description".localized,
                                            preferredStyle: .actionSheet)

    alertController.addAction(UIAlertAction(title: "import_button".localized, style: .default) { _ in
      self.onAction?(.importLocalFiles)
    })

    alertController.addAction(UIAlertAction(title: "create_playlist_button".localized, style: .default) { _ in
      self.showCreateFolderAlert()
    })

    alertController.addAction(UIAlertAction(title: "cancel_button".localized, style: .cancel))

    self.navigationController.present(alertController, animated: true, completion: nil)
  }

  func showDocumentPicker() {
    let providerList = UIDocumentPickerViewController(documentTypes: ["public.audio", "com.pkware.zip-archive", "public.movie"], in: .import)

    providerList.delegate = self.documentPickerDelegate
    providerList.allowsMultipleSelection = true

    UIApplication.shared.isIdleTimerDisabled = true

    self.presentingViewController?.present(providerList, animated: true, completion: nil)
  }

  func showSortOptions() {
    let alert = UIAlertController(title: "sort_files_title".localized, message: nil, preferredStyle: .actionSheet)

    alert.addAction(UIAlertAction(title: "sort_title_button".localized, style: .default, handler: { _ in
      self.onAction?(.sortItems(.metadataTitle))
    }))

    alert.addAction(UIAlertAction(title: "sort_filename_button".localized, style: .default, handler: { _ in
      self.onAction?(.sortItems(.fileName))
    }))

    alert.addAction(UIAlertAction(title: "sort_most_recent_button".localized, style: .default, handler: { _ in
      self.onAction?(.sortItems(.mostRecent))
    }))

    alert.addAction(UIAlertAction(title: "sort_reversed_button".localized, style: .default, handler: { _ in
      self.onAction?(.sortItems(.reverseOrder))
    }))

    alert.addAction(UIAlertAction(title: "cancel_button".localized, style: .cancel, handler: nil))

    self.navigationController.present(alert, animated: true, completion: nil)
  }

  func showMoveOptions(selectedItems: [SimpleLibraryItem], availableFolders: [SimpleLibraryItem]) {
    let alert = UIAlertController(title: "choose_destination_title".localized, message: nil, preferredStyle: .alert)

    if self is FolderListCoordinator {
      alert.addAction(UIAlertAction(title: "library_title".localized, style: .default) { [weak self] _ in
        self?.onAction?(.moveIntoLibrary(items: selectedItems))
      })
    }

    alert.addAction(UIAlertAction(title: "new_playlist_button".localized, style: .default) { _ in
      self.showCreateFolderAlert(placeholder: nil, with: selectedItems)
    })

    let existingFolderAction = UIAlertAction(title: "existing_playlist_button".localized, style: .default) { _ in
      let vc = ItemSelectionViewController()
      vc.items = availableFolders

      vc.onItemSelected = { selectedFolder in
        self.onAction?(.moveIntoFolder(selectedFolder, items: selectedItems))
      }

      let nav = AppNavigationController(rootViewController: vc)
      self.navigationController.present(nav, animated: true, completion: nil)
    }

    existingFolderAction.isEnabled = !availableFolders.isEmpty
    alert.addAction(existingFolderAction)

    alert.addAction(UIAlertAction(title: "cancel_button".localized, style: .cancel))

    self.navigationController.present(alert, animated: true, completion: nil)
  }

  func showDeleteAlert(selectedItems: [SimpleLibraryItem]) {
    let alert = UIAlertController(title: String.localizedStringWithFormat("delete_multiple_items_title".localized, selectedItems.count),
                                  message: "delete_multiple_items_description".localized,
                                  preferredStyle: .alert)

    alert.addAction(UIAlertAction(title: "cancel_button".localized, style: .cancel, handler: nil))

    var deleteActionTitle = "delete_button".localized

    if selectedItems.count == 1,
       let item = selectedItems.first,
       item.type == .folder {
        deleteActionTitle = "delete_deep_button".localized

        alert.title = String(format: "delete_single_item_title".localized, item.title)
        alert.message = "delete_single_playlist_description".localized
        alert.addAction(UIAlertAction(title: "delete_shallow_button".localized, style: .default, handler: { _ in
          self.onAction?(.delete(selectedItems, mode: .shallow))
        }))
    }

    alert.addAction(UIAlertAction(title: deleteActionTitle, style: .destructive, handler: { _ in
      if selectedItems.contains(where: { $0.relativePath == self.playerManager.currentBook?.relativePath }) {
        self.playerManager.stop()
      }

      self.onAction?(.delete(selectedItems, mode: .deep))
    }))

    self.navigationController.present(alert, animated: true, completion: nil)
  }

  func showMoreOptionsAlert(selectedItems: [SimpleLibraryItem], availableFolders: [SimpleLibraryItem]) {
    guard let item = selectedItems.first else {
      return
    }

    let isSingle = selectedItems.count == 1

    let sheetTitle = isSingle ? item.title : "options_button".localized

    let sheet = UIAlertController(title: sheetTitle, message: nil, preferredStyle: .actionSheet)

    let renameAction = UIAlertAction(title: "rename_button".localized, style: .default) { _ in
      self.showRenameAlert(item)
    }

    renameAction.isEnabled = isSingle
    sheet.addAction(renameAction)

    sheet.addAction(UIAlertAction(title: "move_title".localized, style: .default, handler: { _ in
      self.showMoveOptions(selectedItems: selectedItems, availableFolders: availableFolders)
    }))

    sheet.addAction(UIAlertAction(title: "export_button".localized, style: .default, handler: { _ in
      self.showExportController(for: selectedItems)
    }))

    sheet.addAction(UIAlertAction(title: "jump_start_title".localized, style: .default, handler: { [weak self] _ in
      self?.onAction?(.resetPlaybackPosition(selectedItems))
    }))

    let areFinished = selectedItems.filter({ $0.progress != 1.0 }).isEmpty
    let markTitle = areFinished ? "mark_unfinished_title".localized : "mark_finished_title".localized

    sheet.addAction(UIAlertAction(title: markTitle, style: .default, handler: { [weak self] _ in
      self?.onAction?(.markAsFinished(selectedItems, flag: !areFinished))
    }))

    sheet.addAction(UIAlertAction(title: "\("delete_button".localized)", style: .destructive) { _ in
      self.showDeleteAlert(selectedItems: selectedItems)
    })

    sheet.addAction(UIAlertAction(title: "cancel_button".localized, style: .cancel, handler: nil))

    self.navigationController.present(sheet, animated: true, completion: nil)
  }

  func showRenameAlert(_ item: SimpleLibraryItem) {
    let alert = UIAlertController(title: "rename_title".localized, message: nil, preferredStyle: .alert)

    alert.addTextField(configurationHandler: { textfield in
      textfield.placeholder = item.title
      textfield.text = item.title
    })

    alert.addAction(UIAlertAction(title: "cancel_button".localized, style: .cancel, handler: nil))
    alert.addAction(UIAlertAction(title: "rename_button".localized, style: .default) { [weak self] _ in
      if let title = alert.textFields!.first!.text, title != item.title {
        self?.onAction?(.rename(item, newTitle: title))
      }
    })

    self.navigationController.present(alert, animated: true, completion: nil)
  }

  func showExportController(for items: [SimpleLibraryItem]) {
    let providers = items.map { BookActivityItemProvider($0) }

    let shareController = UIActivityViewController(activityItems: providers, applicationActivities: nil)
    shareController.excludedActivityTypes = [.copyToPasteboard]

    self.navigationController.present(shareController, animated: true, completion: nil)
  }

  func reloadItemsWithPadding(padding: Int = 0) {
    // Reload all preceding screens too
    if let coordinator = self.parentCoordinator as? ItemListCoordinator {
      coordinator.reloadItemsWithPadding(padding: padding)
    }

    self.onAction?(.reloadItems(padding))
  }
}
