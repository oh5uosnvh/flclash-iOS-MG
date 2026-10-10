import Foundation
import os

@MainActor
final class CoreEventRelay {
  private let sharedStateStore: SharedStateStore
  private let sendEvent: (String, @escaping (Bool) -> Void) -> Void
  private let sendProviderMessage: (Data) async throws -> String
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "cc.flclash.mg",
    category: "CoreEventRelay"
  )
  private var isStarted = false
  private var inFlightEventFiles = Set<URL>()

  // Restricted-signing fallback: while the tunnel runs, core events buffer
  // in the extension's memory ring and this poll drains them over provider
  // messages (no shared container required).
  private var pollTimer: DispatchSourceTimer?
  private var pollInFlight = false
  private var isTunnelActive = false

  init(
    sharedStateStore: SharedStateStore,
    sendEvent: @escaping (String, @escaping (Bool) -> Void) -> Void,
    sendProviderMessage: @escaping (Data) async throws -> String
  ) {
    self.sharedStateStore = sharedStateStore
    self.sendEvent = sendEvent
    self.sendProviderMessage = sendProviderMessage
  }

  deinit {
    guard isStarted else {
      return
    }
    CFNotificationCenterRemoveObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(self).toOpaque(),
      CFNotificationName(sharedStateStore.eventNotificationName as CFString),
      nil
    )
  }

  func start() {
    guard !isStarted else {
      return
    }
    isStarted = true
    IOSCoreBridge.setEventListener { [weak self] event in
      guard let event,
        !event.isEmpty
      else {
        return
      }
      Task { @MainActor [weak self] in
        self?.sendEvent(event) { _ in }
      }
    }
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(self).toOpaque(),
      CoreEventRelay.eventNotificationCallback,
      sharedStateStore.eventNotificationName as CFString,
      nil,
      .deliverImmediately
    )
    drainEventQueue()
  }

  func drainEventQueue() {
    guard let directory = sharedStateStore.eventQueueDirectory() else {
      log("drainEventQueue skipped: missing app group dir")
      return
    }
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    ) else {
      return
    }
    for fileURL in files
      .filter({ $0.pathExtension == "json" })
      .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      guard inFlightEventFiles.insert(fileURL).inserted else {
        continue
      }
      guard let event = try? String(contentsOf: fileURL, encoding: .utf8),
        !event.isEmpty
      else {
        try? FileManager.default.removeItem(at: fileURL)
        inFlightEventFiles.remove(fileURL)
        continue
      }
      sendEvent(event) { [weak self] delivered in
        Task { @MainActor in
          guard let self else {
            return
          }
          if delivered {
            try? FileManager.default.removeItem(at: fileURL)
          } else {
            self.log("drainEventQueue event not delivered")
          }
          self.inFlightEventFiles.remove(fileURL)
        }
      }
    }
  }

  nonisolated private func handleEventNotification() {
    Task { @MainActor [weak self] in
      self?.drainEventQueue()
      if self?.isTunnelActive == true {
        self?.pollNetworkExtensionEvents()
      }
    }
  }

  /// Called on tunnel state changes: core events reach the app over
  /// provider messages only while a network extension session is active.
  func setTunnelActive(_ active: Bool) {
    isTunnelActive = active
    if active {
      startPolling()
    } else {
      stopPolling()
    }
  }

  private func startPolling() {
    guard pollTimer == nil, isStarted else {
      return
    }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1)
    timer.setEventHandler { [weak self] in
      self?.pollNetworkExtensionEvents()
    }
    timer.resume()
    pollTimer = timer
  }

  private func stopPolling() {
    pollTimer?.cancel()
    pollTimer = nil
  }

  private func pollNetworkExtensionEvents() {
    guard isStarted, isTunnelActive, !pollInFlight else {
      return
    }
    pollInFlight = true
    Task { @MainActor [weak self] in
      defer { self?.pollInFlight = false }
      guard let self else { return }
      let request = Data(
        #"{"id":"drain","method":"neDrainEvents"}"#.utf8
      )
      do {
        let text = try await sendProviderMessage(request)
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
          let events = object["result"] as? [String]
        else {
          return
        }
        for event in events where !event.isEmpty {
          sendEvent(event) { _ in }
        }
      } catch {
        // The session can drop during restarts; the next poll retries.
      }
    }
  }

  private func log(_ message: String) {
    logger.debug("\(message, privacy: .public)")
  }

  private static let eventNotificationCallback: CFNotificationCallback = {
    _, observer, _, _, _ in
    guard let observer else {
      return
    }
    let instance = Unmanaged<CoreEventRelay>
      .fromOpaque(observer)
      .takeUnretainedValue()
    instance.handleEventNotification()
  }
}
