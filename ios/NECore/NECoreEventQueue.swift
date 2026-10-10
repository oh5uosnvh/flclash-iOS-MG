import Foundation
import os

final class NECoreEventQueue {
  private let sharedStateStore: PacketTunnelSharedStateStore
  private let eventQueueDirectoryName = "core-events"
  private let maxEventQueueFiles = 50
  private let logger = Logger(
    subsystem: PacketTunnelEnvironment.extensionBundleIdentifier,
    category: "NECoreEventQueue"
  )

  // Restricted-signing environments have no shared container; events then
  // wait in this bounded ring until the app drains them over a provider
  // message instead of being lost.
  private var memoryEventRing: [Data] = []
  private let memoryRingLock = NSLock()
  private let maxMemoryEventRing = 300

  private var eventsSincePrune = 0

  init(sharedStateStore: PacketTunnelSharedStateStore) {
    self.sharedStateStore = sharedStateStore
  }

  func start() {
    NECoreBridge.setEventListener { [weak self] event in
      guard let self,
        let event,
        !event.isEmpty
      else {
        return
      }
      self.enqueue(event)
    }
  }

  func stop() {
    NECoreBridge.setEventListener(nil)
  }

  private func enqueue(_ event: Data) {
    guard let directory = eventQueueDirectory() else {
      // No shared container: the app drains these over provider messages.
      // The Darwin notification still crosses processes and makes the app
      // poll immediately instead of waiting for its 1s timer.
      enqueueToMemoryRing(event)
      notifyEventAvailable()
      return
    }
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
      let fileName = "\(timestamp)-\(UUID().uuidString)"
      let fileURL = directory.appendingPathComponent("\(fileName).json")
      let temporaryURL = directory.appendingPathComponent(".\(fileName).tmp")
      do {
        try event.write(to: temporaryURL)
        try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
      } catch {
        try? FileManager.default.removeItem(at: temporaryURL)
        throw error
      }
      eventsSincePrune += 1
      if eventsSincePrune >= maxEventQueueFiles {
        eventsSincePrune = 0
        prune(in: directory)
      }
      notifyEventAvailable()
    } catch {
      logger.error(
        "enqueue failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func prune(in directory: URL) {
    var files = eventFiles(in: directory)
    let overflowCount = files.count - maxEventQueueFiles

    var remaining = overflowCount
    while remaining > 0 && !files.isEmpty {
      removeOldestEventFile(&files)
      remaining -= 1
    }
  }

  private func eventFiles(in directory: URL) -> [URL] {
    guard let fileURLs = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey]
    ) else {
      return []
    }
    return fileURLs.filter { fileURL in
      fileURL.pathExtension == "json" &&
        (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?
          .isRegularFile == true
    }.sorted { lhs, rhs in
      lhs.lastPathComponent < rhs.lastPathComponent
    }
  }

  private func removeOldestEventFile(_ files: inout [URL]) {
    let fileURL = files.removeFirst()
    do {
      try FileManager.default.removeItem(at: fileURL)
    } catch {
      logger.warning(
        "prune failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func enqueueToMemoryRing(_ event: Data) {
    memoryRingLock.lock()
    memoryEventRing.append(event)
    if memoryEventRing.count > maxMemoryEventRing {
      memoryEventRing.removeFirst(memoryEventRing.count - maxMemoryEventRing)
    }
    memoryRingLock.unlock()
  }

  /// Returns and clears the events buffered while no shared container was
  /// available. Called by the native provider-message handler.
  func drainMemoryEvents() -> [Data] {
    memoryRingLock.lock()
    defer { memoryRingLock.unlock() }
    let events = memoryEventRing
    memoryEventRing.removeAll()
    return events
  }

  private func eventQueueDirectory() -> URL? {
    sharedStateStore.appGroupDirectory()?.appendingPathComponent(
      eventQueueDirectoryName,
      isDirectory: true
    )
  }

  private func notifyEventAvailable() {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(
        PacketTunnelEnvironment.eventNotificationName as CFString
      ),
      nil,
      nil,
      true
    )
  }
}
