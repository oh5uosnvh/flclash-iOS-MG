import Foundation
import NetworkExtension
import WidgetKit
import os

#if canImport(Shared)
import Shared
#endif

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let sharedStateStore = PacketTunnelSharedStateStore()
  private let networkConfiguration = PacketTunnelNetworkConfiguration()
  private let startupLock = NSLock()
  private var startupCancelled = false
  private var preparationSession: URLSession?
  private lazy var eventQueue = NECoreEventQueue(
    sharedStateStore: sharedStateStore
  )
  private let logger = Logger(
    subsystem: PacketTunnelEnvironment.extensionBundleIdentifier,
    category: "PacketTunnelProvider"
  )

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    logger.info("startTunnel begin")
    startupLock.lock()
    startupCancelled = false
    startupLock.unlock()
    let flight = FlightRecorder.shared
    flight.record("startTunnel begin mem=\(Self.availableMemoryMB())MB")
    NECoreBridge.neReport("startTunnel begin")
    // Name the shared container actually in use before anything reads
    // state; this separates "no shared container" from later failures.
    if let shared = SharedLocation.resolve() {
      flight.record("sharedGroup=\(shared.groupID) source=\(shared.source)")
    } else {
      flight.record("sharedGroup=none; payload/sandbox fallbacks active")
    }
    startMemoryProbe()
    startResourceHeartbeat()
    sharedStateStore.clearRunTime()
    sharedStateStore.attachLaunchPayload(
      options,
      providerConfiguration: (protocolConfiguration as? NETunnelProviderProtocol)?
        .providerConfiguration
    )
    flight.record(
      "payload \(sharedStateStore.launchPayloadAvailable() ? "attached" : "absent")"
    )
    // Defused: ControlCenter.reloadControls performs XPC to a remote
    // service and has been implicated in early NE process teardown on
    // sideloaded builds. The widget refresh is cosmetic; skip it during
    // startup and let the app-side refresh cover it.
    // reloadControlWidget()
    flight.record("preparing core runtime")
    prepareCoreRuntime { [weak self] error in
      guard let self else { return }
      self.startupLock.lock()
      let cancelled = self.startupCancelled
      self.startupLock.unlock()
      if cancelled {
        completionHandler(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        return
      }
      if let error {
        self.stopMemoryProbe()
        self.stopResourceHeartbeat()
        flight.record("FATAL: runtime preparation \(error.localizedDescription)")
        flight.dumpForSystemLog(self.logger)
        completionHandler(error)
        return
      }
      self.startPreparedTunnel(completionHandler: completionHandler)
    }
  }

  private func startPreparedTunnel(completionHandler: @escaping (Error?) -> Void) {
    let flight = FlightRecorder.shared
    flight.record("core runtime ready")
    guard let snapshot = sharedStateStore.loadVPNOptionsSnapshot() else {
      flight.record("FATAL: vpn options missing (payload+defaults)")
      flight.dumpForSystemLog(logger)
      logger.error("startTunnel failed: missing vpn options")
      completionHandler(PacketTunnelProviderError.missingVPNOptions)
      return
    }
    let vpnOptions = snapshot.options
    flight.record("options decoded stack=\(vpnOptions.stack) mtu=\(vpnOptions.mtu)")
    logger.info(
      "startTunnel options stack=\(vpnOptions.stack, privacy: .public) ipv6=\(vpnOptions.ipv6, privacy: .public) captureDns=\(vpnOptions.captureDns, privacy: .public) systemProxy=\(vpnOptions.systemProxy, privacy: .public)"
    )

    setTunnelNetworkSettings(
      networkConfiguration.makeSettings(for: vpnOptions)
    ) { error in
      if let error {
        flight.record("FATAL: settings error \(error)")
        flight.dumpForSystemLog(self.logger)
        self.logger.error(
          "setTunnelNetworkSettings failed: \(error.localizedDescription, privacy: .public)"
        )
        completionHandler(error)
        return
      }
      flight.record("settings applied")
      self.logger.info("setTunnelNetworkSettings completed")
      guard let tunnelFileDescriptor =
        self.networkConfiguration.tunnelFileDescriptor()
      else {
        flight.record("FATAL: tunnel fd not found")
        flight.dumpForSystemLog(self.logger)
        self.logger.error(
          "startTunnel failed: tunnel file descriptor missing"
        )
        completionHandler(
          PacketTunnelProviderError.couldNotDetermineFileDescriptor
        )
        return
      }
      self.logger.debug(
        "startTunnel fileDescriptor=\(tunnelFileDescriptor, privacy: .public)"
      )
      self.eventQueue.start()
      let initParams = self.sharedStateStore.makeInitParams()
      let setupParams = self.sharedStateStore.loadSetupParams()
      flight.record("quickSetup init=\(initParams) setupBytes=\(setupParams.count)")
      self.logger.info(
        "quickSetup initParams=\(initParams, privacy: .public)"
      )
      NECoreBridge.quickSetup(
        withInitParams: initParams,
        setupParams: setupParams
      ) { result in
        if let result,
          !result.isEmpty
        {
          let message = String(data: result, encoding: .utf8) ??
            "unknown core error"
          flight.record("FATAL: quickSetup \(message)")
          flight.dumpForSystemLog(self.logger)
          self.logger.error(
            "quickSetup failed: \(message, privacy: .public)"
          )
          completionHandler(PacketTunnelProviderError.couldNotStartCoreTun)
          return
        }
        flight.record("quickSetup completed")
        self.logger.info("quickSetup completed")
        let coreTunOptions = CoreTunOptions(
          stack: vpnOptions.stack,
          address: self.networkConfiguration.tunAddress(for: vpnOptions),
          dns: self.networkConfiguration.tunDNS(for: vpnOptions),
          mtu: vpnOptions.mtu,
          disableIcmpForwarding: vpnOptions.disableIcmpForwarding,
          endpointIndependentNat: vpnOptions.endpointIndependentNat,
          congestionController: vpnOptions.congestionController,
          recvMsgX: vpnOptions.recvMsgX,
          sendMsgX: vpnOptions.sendMsgX
        )
        guard let coreTunOptionsData = try? JSONEncoder().encode(coreTunOptions)
        else {
          completionHandler(PacketTunnelProviderError.couldNotStartCoreTun)
          return
        }
        let started = NECoreBridge.startTun(
          withFileDescriptor: tunnelFileDescriptor,
          options: coreTunOptionsData
        )
        flight.record("startTun=\(started) opts=\(String(data: coreTunOptionsData, encoding: .utf8) ?? "?")")
        if !started {
          flight.dumpForSystemLog(self.logger)
        }
        self.logger.info(
          "NECoreBridge.startTun result=\(started, privacy: .public)"
        )
        NECoreBridge.neReport("startTun result=\(started ? 1 : 0) availableMem=\(Self.availableMemoryMB())MB")
        if started {
          self.sharedStateStore.saveRunTime(vpnOptions: snapshot.data)
        }
        flight.record(
          started ? "TUNNEL STARTED" : "FATAL: startTun returned false"
        )
        completionHandler(
          started ? nil : PacketTunnelProviderError.couldNotStartCoreTun
        )
      }
    }
  }

  override func sleep(completionHandler: @escaping () -> Void) {
    logger.info("sleep: suspending tunnel")
    NECoreBridge.setSuspended(true)
    completionHandler()
  }

  override func wake() {
    logger.info("wake: resuming tunnel")
    NECoreBridge.setSuspended(false)
  }

  override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    startupLock.lock()
    startupCancelled = true
    let session = preparationSession
    preparationSession = nil
    startupLock.unlock()
    session?.invalidateAndCancel()
    logger.info("stopTunnel reason=\(reason.rawValue, privacy: .public)")
    NECoreBridge.neReport(String(format: "stopTunnel reason=%d availableMem=%dMB footprint=%.2fMB", reason.rawValue, Self.availableMemoryMB(), Self.footprintMB()))
    stopMemoryProbe()
    stopResourceHeartbeat()
    sharedStateStore.clearRunTime()
    reloadControlWidget()
    eventQueue.stop()
    NECoreBridge.stopTun()
    guard reason == .userInitiated else {
      completionHandler()
      return
    }
    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      if let error {
        self.logger.error(
          "stopTunnel loadAllFromPreferences error=\(error.localizedDescription, privacy: .public)"
        )
        completionHandler()
        return
      }
      guard let manager = managers?.first(where: { manager in
        guard let proto = manager.protocolConfiguration
          as? NETunnelProviderProtocol
        else {
          return false
        }
        return proto.providerBundleIdentifier ==
          PacketTunnelEnvironment.extensionBundleIdentifier
      }) else {
        completionHandler()
        return
      }
      manager.isOnDemandEnabled = false
      manager.saveToPreferences { error in
        if let error {
          self.logger.error(
            "stopTunnel saveToPreferences error=\(error.localizedDescription, privacy: .public)"
          )
        }
        completionHandler()
      }
    }
  }

  override func handleAppMessage(
    _ messageData: Data,
    completionHandler: ((Data?) -> Void)?
  ) {
    logger.debug(
      "handleAppMessage bytes=\(messageData.count, privacy: .public)"
    )
    guard let completionHandler else {
      logger.warning("handleAppMessage ignored: missing completion handler")
      return
    }

    // Native diagnostics answer without the Go core; the app pulls this on
    // demand to merge the extension flight log into its exported log.
    if let nativeResponse = nativeDiagnosticResponse(for: messageData) {
      logger.debug("handleAppMessage native diagnostic served")
      completionHandler(nativeResponse)
      return
    }

    // The Go dispatcher may never call back (core restarting or busy); the
    // system then reports an empty response to the app. Answer exactly once,
    // and add a watchdog so method calls fail with a defined error instead
    // of vanishing.
    let completionLock = NSLock()
    var answered = false
    let complete: (Data?) -> Void = { data in
      completionLock.lock()
      let isFirst = !answered
      answered = true
      completionLock.unlock()
      guard isFirst else {
        return
      }
      completionHandler(data)
    }
    let messageDataCopy = messageData
    let watchdog = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.logger.warning(
        "handleAppMessage watchdog fired; core did not answer"
      )
      complete(
        self.methodErrorResponse(
          messageData: messageDataCopy,
          code: "core_timeout",
          message: "core method did not answer"
        )
      )
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)

    NECoreBridge.invokeMethod(messageData) { response in
      watchdog.cancel()
      guard let response else {
        self.logger.warning("handleAppMessage empty core response")
        complete(
          self.methodErrorResponse(
            messageData: messageData,
            code: "empty_response",
            message: "empty core response"
          )
        )
        return
      }
      self.logger.debug(
        "handleAppMessage response bytes=\(response.count, privacy: .public)"
      )
      complete(response)
    }
  }

  private func nativeDiagnosticResponse(for messageData: Data) -> Data? {
    guard
      let object = try? JSONSerialization.jsonObject(with: messageData)
        as? [String: Any],
      object["method"] as? String == "neDiagnosticLog"
    else {
      return nil
    }
    var payload: [String: Any] = [
      "result": FlightRecorder.shared.snapshot(),
      "error": NSNull(),
    ]
    if let id = object["id"] {
      payload["id"] = id
    }
    return try? JSONSerialization.data(withJSONObject: payload)
  }

  private func methodErrorResponse(
    messageData: Data,
    code: String,
    message: String
  ) -> Data? {
    var payload: [String: Any] = [
      "result": NSNull(),
      "error": [
        "code": code,
        "message": message,
        "details": NSNull(),
      ],
    ]
    if let id = methodCallID(messageData) {
      payload["id"] = id
    }
    return try? JSONSerialization.data(withJSONObject: payload)
  }

  private func methodCallID(_ messageData: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: messageData)
      as? [String: Any]
    else {
      return nil
    }
    return object["id"] as? String
  }

  private func reloadControlWidget() {
    if #available(iOS 18.0, *) {
      ControlCenter.shared.reloadControls(
        ofKind: PacketTunnelEnvironment.widgetIdentifier
      )
    }
  }
}

private struct CoreTunOptions: Encodable {
  let stack: String
  let address: String
  let dns: String
  let mtu: Int
  let disableIcmpForwarding: Bool
  let endpointIndependentNat: Bool
  let congestionController: String
  let recvMsgX: Bool
  let sendMsgX: Bool
}

private enum PacketTunnelProviderError: LocalizedError {
  case missingVPNOptions
  case couldNotDetermineFileDescriptor
  case couldNotStartCoreTun

  var errorDescription: String? {
    switch self {
    case .missingVPNOptions:
      return "missing VPN options"
    case .couldNotDetermineFileDescriptor:
      return "could not determine tunnel file descriptor"
    case .couldNotStartCoreTun:
      return "could not start core TUN"
    }
  }
}

// MARK: - Memory probe

// MARK: - Runtime home preparation

extension PacketTunnelProvider {
  /// Prepare on disk before starting Go. Low-memory geodata initialization
  /// does not download missing databases; MMDB access can terminate the core.
  /// URLSession download tasks avoid retaining whole databases in NE memory.
  func prepareCoreRuntime(completionHandler: @escaping (Error?) -> Void) {
    let store = sharedStateStore
    let flight = FlightRecorder.shared
    guard let home = store.homeDirectoryForCore() else {
      completionHandler(NSError(domain: "FlClash.Startup", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "No core home: launch payload and App Group unavailable"]))
      return
    }
    flight.record("home=\(home.path) appGroup=\(store.usesAppGroupHome())")
    do {
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      if let data = store.configYamlDataFromPayload() {
        try data.write(to: home.appendingPathComponent("config.yaml"), options: .atomic)
        flight.record("config.yaml written bytes=\(data.count)")
      } else if !FileManager.default.fileExists(atPath: home.appendingPathComponent("config.yaml").path) {
        throw NSError(domain: "FlClash.Startup", code: 2,
          userInfo: [NSLocalizedDescriptionKey: "No config.yaml in launch payload or core home"])
      }
    } catch {
      completionHandler(error)
      return
    }
    let downloads = store.missingGeoDataDownloads()
    guard !downloads.isEmpty else {
      flight.record("geo complete, no downloads")
      completionHandler(nil)
      return
    }
    flight.record("geo fetching to disk count=\(downloads.count)")
    let group = DispatchGroup()
    let errors = RuntimePreparationErrors()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 20
    let session = URLSession(configuration: configuration)
    startupLock.lock()
    preparationSession = session
    let cancelled = startupCancelled
    startupLock.unlock()
    if cancelled {
      session.invalidateAndCancel()
      completionHandler(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
      return
    }
    for item in downloads {
      group.enter()
      session.downloadTask(with: item.remoteURL) { temporaryURL, response, error in
        defer { group.leave() }
        do {
          if let error { throw error }
          guard let temporaryURL,
            let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode),
            !(http.mimeType?.lowercased().contains("text/html") ?? false),
            let size = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size > 0
          else {
            throw NSError(domain: "FlClash.Startup", code: 3,
              userInfo: [NSLocalizedDescriptionKey: "Invalid download for \(item.destination.lastPathComponent), HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"])
          }
          try FileManager.default.moveItem(at: temporaryURL, to: item.destination)
          flight.record("geo stored \(item.destination.lastPathComponent) bytes=\(size)")
        } catch {
          errors.record(error)
          flight.record("geo failed \(item.destination.lastPathComponent): \(error.localizedDescription)")
        }
      }.resume()
    }
    group.notify(queue: .global()) {
      session.finishTasksAndInvalidate()
      self.startupLock.lock()
      self.preparationSession = nil
      self.startupLock.unlock()
      completionHandler(errors.first)
    }
  }
}

private final class RuntimePreparationErrors: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Error?

  func record(_ error: Error) {
    lock.lock()
    defer { lock.unlock() }
    if stored == nil { stored = error }
  }

  var first: Error? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}

/// Reports the NE process memory headroom every few seconds so the app log
/// shows whether jetsam pressure precedes the ~10s tunnel death. The probe
/// stops itself when the extension is torn down.
private var memoryProbeTimer: DispatchSourceTimer?
private var memoryPressureSource: DispatchSourceMemoryPressure?
private var resourceHeartbeatTimer: DispatchSourceTimer?
private var lastReclaimUptime: TimeInterval = 0

extension PacketTunnelProvider {
  /// Cooldown between reclaim passes so a single pressure spike cannot
  /// thrash the live connection pools.
  static let reclaimCooldown: TimeInterval = 10
  /// Reclaim thresholds on os_proc_available_memory headroom.
  static let warningAvailableMB = 14
  static let criticalAvailableMB = 10

  static func availableMemoryMB() -> Int {
    let available = os_proc_available_memory()
    if available == 0 {
      return 0
    }
    return Int(available) / 1_048_576
  }

  /// phys_footprint in MB with 0.01MB resolution (this is the number jetsam
  /// enforces; sub-MB movement matters near the line).
  static func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
      ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    return Double(info.phys_footprint) / 1_048_576.0
  }

  func startMemoryProbe() {
    stopMemoryProbe()
    NECoreBridge.neReport(
      String(format: "memprobe armed available=%dMB footprint=%.2fMB", Self.availableMemoryMB(), Self.footprintMB())
    )
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
    timer.schedule(deadline: .now() + 3, repeating: 5)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      NECoreBridge.neReport(
        String(format: "memprobe available=%dMB footprint=%.2fMB", Self.availableMemoryMB(), Self.footprintMB())
      )
      _ = self
    }
    timer.resume()
    memoryProbeTimer = timer
  }

  func stopMemoryProbe() {
    memoryProbeTimer?.cancel()
    memoryProbeTimer = nil
  }

  /// Native resource heartbeat: watches the jetsam footprint and reacts to
  /// system memory-pressure events by forcing the Go core to release memory.
  /// Same loop the working reference build runs (threshold + cooldown +
  /// reclaim), aligned on the os_memory_pressure / memory_pressure_* events.
  func startResourceHeartbeat() {
    stopResourceHeartbeat()

    let pressure = DispatchSource.makeMemoryPressureSource(
      eventMask: [.warning, .critical],
      queue: DispatchQueue.global(qos: .userInitiated)
    )
    pressure.setEventHandler { [weak self] in
      guard let self else { return }
      let data = memoryPressureSource?.data ?? []
      if data.contains(.critical) {
        self.reclaimMemory(level: "critical")
      } else if data.contains(.warning) {
        self.reclaimMemory(level: "warning")
      }
    }
    pressure.resume()
    memoryPressureSource = pressure

    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
    timer.schedule(deadline: .now() + 2, repeating: 2)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      let available = Self.availableMemoryMB()
      let footprint = Self.footprintMB()
      let fpStr = String(format: "%.2f", footprint)
      NECoreBridge.neReport(
        "heartbeat footprint_mb=\(fpStr) available_mb=\(available)"
      )
      if available <= Self.criticalAvailableMB {
        self.reclaimMemory(level: "critical")
      } else if available <= Self.warningAvailableMB {
        self.reclaimMemory(level: "warning")
      }
    }
    timer.resume()
    resourceHeartbeatTimer = timer
  }

  func stopResourceHeartbeat() {
    resourceHeartbeatTimer?.cancel()
    resourceHeartbeatTimer = nil
    memoryPressureSource?.cancel()
    memoryPressureSource = nil
  }

  func reclaimMemory(level: String) {
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastReclaimUptime >= Self.reclaimCooldown else {
      return
    }
    lastReclaimUptime = now

    let before = String(format: "%.2f", Self.footprintMB())
    NECoreBridge.neReport("memory_pressure_\(level) footprint_mb=\(before)")
    NECoreBridge.forceGc()
    if level == "critical" {
      NECoreBridge.releaseConfig()
    }
    let after = String(format: "%.2f", Self.footprintMB())
    NECoreBridge.neReport(
      "memory_pressure_reclaimed footprint_mb=\(after) before_mb=\(before)"
    )
  }
}
