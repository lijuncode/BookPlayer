//
//  SyncJobScheduler.swift
//  BookPlayer
//
//  Created by gianni.carlo on 4/8/22.
//  Copyright © 2022 Tortuga Power. All rights reserved.
//

import Combine
import Foundation
import SwiftQueue

public protocol JobSchedulerProtocol {
  /// Uploads the metadata for the first time to the server
  func scheduleLibraryItemUploadJob(for item: SyncableItem) throws
  /// Update existing metadata in the server
  func scheduleMetadataUpdateJob(with relativePath: String, parameters: [String: Any])
  /// Move item to destination
  func scheduleMoveItemJob(with relativePath: String, to parentFolder: String?)
  /// Delete item
  func scheduleDeleteJob(with relativePath: String, mode: DeleteMode)
  /// Create or update a bookmark
  func scheduleSetBookmarkJob(
    with relativePath: String,
    time: Double,
    note: String?
  )
  /// Delete a bookmark
  func scheduleDeleteBookmarkJob(with relativePath: String, time: Double)
  /// Cancel all stored and ongoing jobs
  func cancelAllJobs()
}

public class SyncJobScheduler: JobSchedulerProtocol, BPLogger {
  let libraryJobsPersister: UserDefaultsPersister
  var libraryQueueManager: SwiftQueueManager!
  private var disposeBag = Set<AnyCancellable>()

  public init() {
    self.libraryJobsPersister = UserDefaultsPersister(key: LibraryItemSyncJob.type)

    recreateQueue()
    bindObservers()
  }

  func bindObservers() {
    NotificationCenter.default.publisher(for: .uploadCompleted)
      .sink { [weak self] notification in
        guard
          let task = notification.object as? URLSessionTask,
          let relativePath = task.taskDescription
        else { return }

        do {
          let hardLinkURL = FileManager.default.temporaryDirectory.appendingPathComponent(relativePath)
          try FileManager.default.removeItem(at: hardLinkURL)
        } catch {
          Self.logger.trace("Failed to delete hard link for \(relativePath): \(error.localizedDescription)")
        }

        self?.libraryQueueManager.cancelOperations(uuid: "\(JobType.upload.identifier)/\(relativePath)")
      }
      .store(in: &disposeBag)

    NotificationCenter.default.publisher(for: .recreateQueue, object: nil)
      .sink { [weak self] _ in
        self?.recreateQueue()
      }
      .store(in: &disposeBag)
  }

  private func createHardLink(for item: SyncableItem) throws {
    let hardLinkURL = FileManager.default.temporaryDirectory.appendingPathComponent(item.relativePath)

    let fileURL = DataManager.getProcessedFolderURL().appendingPathComponent(item.relativePath)

    try FileManager.default.linkItem(at: fileURL, to: hardLinkURL)
  }

  public func scheduleLibraryItemUploadJob(for item: SyncableItem) throws {
    /// Create hard link to file location in case the user moves the item around in the library
    try createHardLink(for: item)

    var parameters: [String: Any] = [
      "relativePath": item.relativePath,
      "originalFileName": item.originalFileName,
      "title": item.title,
      "details": item.details,
      "currentTime": item.currentTime,
      "duration": item.duration,
      "percentCompleted": item.percentCompleted,
      "isFinished": item.isFinished,
      "orderRank": item.orderRank,
      "type": item.type.rawValue,
      "jobType": JobType.upload.rawValue
    ]

    if let lastPlayTimestamp = item.lastPlayDateTimestamp {
      parameters["lastPlayDateTimestamp"] = Int(lastPlayTimestamp)
    } else {
      parameters["lastPlayDateTimestamp"] = nil
    }

    if let speed = item.speed {
      parameters["speed"] = speed
    }

    JobBuilder(type: LibraryItemSyncJob.type)
      .singleInstance(forId: "\(JobType.upload.identifier)/\(item.relativePath)")
      .persist()
      .retry(limit: .unlimited)
      .internet(atLeast: .wifi)
      .with(params: parameters)
      .schedule(manager: libraryQueueManager)
  }

  public func scheduleMoveItemJob(with relativePath: String, to parentFolder: String?) {
    JobBuilder(type: LibraryItemSyncJob.type)
      .singleInstance(forId: "\(JobType.move.identifier)/\(relativePath)")
      .persist()
      .retry(limit: .unlimited)
      .internet(atLeast: .cellular)
      .with(params: [
        "relativePath": relativePath,
        "origin": relativePath,
        "destination": parentFolder ?? "",
        "jobType": JobType.move.rawValue
      ])
      .schedule(manager: libraryQueueManager)
  }

  /// Note: folder renames originalFilename property
  public func scheduleMetadataUpdateJob(with relativePath: String, parameters: [String: Any]) {
    var parameters = parameters
    parameters["jobType"] = JobType.update.rawValue

    JobBuilder(type: LibraryItemSyncJob.type)
      .singleInstance(forId: "\(JobType.update.identifier)/\(relativePath)", override: true)
      .persist()
      .retry(limit: .limited(3))
      .internet(atLeast: .cellular)
      .with(params: parameters)
      .schedule(manager: libraryQueueManager)
  }

  public func scheduleDeleteJob(with relativePath: String, mode: DeleteMode) {
    let jobType: JobType

    switch mode {
    case .deep:
      jobType = JobType.delete
    case .shallow:
      jobType = JobType.shallowDelete
    }

    JobBuilder(type: LibraryItemSyncJob.type)
      .singleInstance(forId: "\(jobType.identifier)/\(relativePath)")
      .persist()
      .retry(limit: .limited(3))
      .internet(atLeast: .cellular)
      .with(params: [
        "relativePath": relativePath,
        "jobType": jobType.rawValue
      ])
      .schedule(manager: libraryQueueManager)
  }

  public func scheduleDeleteBookmarkJob(with relativePath: String, time: Double) {
    JobBuilder(type: LibraryItemSyncJob.type)
      .singleInstance(forId: "\(JobType.deleteBookmark.identifier)/\(relativePath)")
      .persist()
      .retry(limit: .unlimited)
      .internet(atLeast: .cellular)
      .with(params: [
        "relativePath": relativePath,
        "time": time,
        "jobType": JobType.deleteBookmark.rawValue
      ])
      .schedule(manager: libraryQueueManager)
  }

  public func scheduleSetBookmarkJob(
    with relativePath: String,
    time: Double,
    note: String?
  ) {
    var params: [String: Any] = [
      "relativePath": relativePath,
      "time": time,
      "jobType": JobType.setBookmark.rawValue
    ]

    if let note {
      params["note"] = note
    }

    JobBuilder(type: LibraryItemSyncJob.type)
      .singleInstance(forId: "\(JobType.setBookmark.identifier)/\(relativePath)")
      .persist()
      .retry(limit: .unlimited)
      .internet(atLeast: .cellular)
      .with(params: params)
      .schedule(manager: libraryQueueManager)
  }

  public func cancelAllJobs() {
    libraryQueueManager.cancelAllOperations()
    libraryJobsPersister.clearAll()
  }

  public func recreateQueue() {
    /// Suspend queue if it's already created
    if libraryQueueManager != nil {
      libraryQueueManager.isSuspended = true
    }

    libraryQueueManager = SwiftQueueManagerBuilder(creator: LibraryItemUploadJobCreator())
      .set(persister: libraryJobsPersister)
      .set(listener: self)
      .build()
  }
}

extension SyncJobScheduler: JobListener {
  public func onJobScheduled(job: SwiftQueue.JobInfo) {
    Self.logger.trace("Schedule job for \(job.params["relativePath"] as? String)")

    UserDefaults.standard.set(
      true,
      forKey: Constants.UserDefaults.hasQueuedJobs.rawValue
    )
  }

  public func onBeforeRun(job: SwiftQueue.JobInfo) {}

  public func onAfterRun(job: SwiftQueue.JobInfo, result: SwiftQueue.JobCompletion) {}

  public func onTerminated(job: SwiftQueue.JobInfo, result: SwiftQueue.JobCompletion) {
    Self.logger.trace("Terminated job for \(job.params["relativePath"] as? String)")

    guard
      let pendingOperations = libraryQueueManager.getAll()["GLOBAL"],
      pendingOperations.isEmpty
    else { return }

    UserDefaults.standard.set(
      false,
      forKey: Constants.UserDefaults.hasQueuedJobs.rawValue
    )
  }
}