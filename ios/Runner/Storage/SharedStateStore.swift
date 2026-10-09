import Foundation
import WidgetKit

final class SharedStateStore {
  private let sharedStateKey = "sharedState"
  private let setupParamsKey = "setupParams"
  private let runTimeKey = "runTime"

  private let eventQueueDirectoryName = "core-events"

  let appGroupIdentifier = "group.\(Bundle.main.bundleIdentifier!)"
  let eventNotificationName = "\(Bundle.main.bundleIdentifier!).NECore.event"

  func activeVpnOptions() -> String? {
    guard let data = UserDefaults(suiteName: appGroupIdentifier)?
      .data(forKey: "activeVpnOptions")
    else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  func saveSharedState(_ data: Data) -> Bool {
    // A private copy is required when signing did not grant the expected
    // App Group. Group defaults alone are not a cross-process fallback.
    let privateDefaults = UserDefaults.standard
    let groupDefaults = appGroupIsUsable()
      ? UserDefaults(suiteName: appGroupIdentifier) : nil
    let previousControlDisplayState = controlDisplayState(from: savedSharedState())
    let stores = [privateDefaults] + (groupDefaults.map { [$0] } ?? [])
    if let json = try? JSONSerialization.jsonObject(with: data)
      as? [String: Any],
      let setupParams = json[setupParamsKey],
      !(setupParams is NSNull),
      JSONSerialization.isValidJSONObject(setupParams),
      let setupData = try? JSONSerialization.data(withJSONObject: setupParams)
    {
      for store in stores {
        store.set(setupData, forKey: setupParamsKey)
      }
    }
    for store in stores {
      store.set(data, forKey: sharedStateKey)
      store.synchronize()
    }
    if previousControlDisplayState != controlDisplayState(from: data),
      #available(iOS 18.0, *)
    {
      ControlCenter.shared.reloadControls(
        ofKind: "\(Bundle.main.bundleIdentifier!).Widget"
      )
    }
    return true
  }

  private func controlDisplayState(
    from data: Data?
  ) -> (showProfileName: Bool, profileName: String?) {
    guard let data,
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return (true, nil)
    }
    let showProfileName = json["showQuickSettingsProfileName"] as? Bool ?? true
    return (
      showProfileName,
      showProfileName ? json["currentProfileName"] as? String : nil
    )
  }

  private func savedSharedState() -> Data? {
    if let data = UserDefaults.standard.data(forKey: sharedStateKey) {
      return data
    }
    guard appGroupIsUsable() else { return nil }
    return UserDefaults(suiteName: appGroupIdentifier)?.data(forKey: sharedStateKey)
  }

  func loadTunnelConfiguration() -> TunnelConfiguration {
    guard let data = savedSharedState(),
      let sharedState = try? JSONDecoder().decode(
        SharedStatePayload.self,
        from: data
      )
    else {
      return TunnelConfiguration()
    }
    return TunnelConfiguration(
      options: sharedState.vpnOptions?.networkExtensionOptions ??
        NetworkExtensionOptions(),
      excludeSSIDs: sharedState.excludeSSIDs ?? [],
      alwaysOn: sharedState.alwaysOn ?? false
    )
  }

  func appGroupDirectory() -> URL? {
    FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupIdentifier
    )
  }

  func appGroupIsUsable() -> Bool {
    appGroupDirectory() != nil
  }

  func eventQueueDirectory() -> URL? {
    appGroupDirectory()?.appendingPathComponent(
      eventQueueDirectoryName,
      isDirectory: true
    )
  }

  func runTime() -> Int {
    UserDefaults(suiteName: appGroupIdentifier)?
      .integer(forKey: runTimeKey) ?? 0
  }

  // MARK: Launch payload (providerConfiguration)

  // The network extension reads its launch data from the provider
  // configuration of the saved VPN profile, so a restricted signing
  // environment without a working shared container can still start the
  // tunnel. App Group data stays the fast path whenever it is usable.
  private let geoDataURLs: [String: String] = [
    "geosite": "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat",
    "geoip": "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb",
    "asn": "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/GeoLite2-ASN.mmdb",
  ]

  private let maxConfigYamlPayloadBytes = 4_000_000

  func configYamlCandidateURLs() -> [URL] {
    var urls: [URL] = []
    if let appGroup = appGroupDirectory() {
      urls.append(appGroup.appendingPathComponent("config.yaml"))
    }
    let fileManager = FileManager.default
    if let supportDir = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first {
      urls.append(supportDir.appendingPathComponent("config.yaml"))
      if let bundleID = Bundle.main.bundleIdentifier {
        urls.append(
          supportDir.appendingPathComponent(bundleID)
            .appendingPathComponent("config.yaml")
        )
      }
    }
    return urls
  }

  func loadConfigYamlForLaunch() -> String? {
    for url in configYamlCandidateURLs() {
      if let text = try? String(contentsOf: url, encoding: .utf8),
        !text.isEmpty
      {
        return text
      }
    }
    return nil
  }

  func makeLaunchPayload() -> [String: Any]? {
    guard
      let sharedData = savedSharedState(),
      let shared = try? JSONSerialization.jsonObject(with: sharedData)
        as? [String: Any]
    else {
      return nil
    }
    guard let vpnOptions = shared["vpnOptions"] else {
      return nil
    }
    var payload: [String: Any] = [
      "launchPayloadVersion": 1,
      "vpnOptions": vpnOptions,
    ]
    if let setupParams = shared[setupParamsKey], !(setupParams is NSNull) {
      payload["setupParams"] = setupParams
    }
    if let configYaml = loadConfigYamlForLaunch(),
      configYaml.utf8.count <= maxConfigYamlPayloadBytes
    {
      payload["configYaml"] = configYaml
    }
    payload["geoURLs"] = geoDataURLs
    return payload
  }
}

struct TunnelConfiguration {
  let options: NetworkExtensionOptions
  let excludeSSIDs: [String]
  let alwaysOn: Bool

  init(
    options: NetworkExtensionOptions = NetworkExtensionOptions(),
    excludeSSIDs: [String] = [],
    alwaysOn: Bool = false
  ) {
    self.options = options
    self.excludeSSIDs = excludeSSIDs
    self.alwaysOn = alwaysOn
  }
}

struct NetworkExtensionOptions {
  var includeAllNetworks = false
  var excludeLocalNetworks = true
  var excludeAPNs = true
  var excludeCellularServices = true
  var enforceRoutes = false
  var excludeDeviceCommunication = true
}

private struct SharedStatePayload: Decodable {
  let vpnOptions: VpnOptionsPayload?
  let excludeSSIDs: [String]?
  let alwaysOn: Bool?
}

private struct VpnOptionsPayload: Decodable {
  let includeAllNetworks: Bool?
  let excludeLocalNetworks: Bool?
  let excludeAPNs: Bool?
  let excludeCellularServices: Bool?
  let enforceRoutes: Bool?
  let excludeDeviceCommunication: Bool?

  var networkExtensionOptions: NetworkExtensionOptions {
    NetworkExtensionOptions(
      includeAllNetworks: includeAllNetworks ?? false,
      excludeLocalNetworks: excludeLocalNetworks ?? true,
      excludeAPNs: excludeAPNs ?? true,
      excludeCellularServices: excludeCellularServices ?? true,
      enforceRoutes: enforceRoutes ?? false,
      excludeDeviceCommunication: excludeDeviceCommunication ?? true
    )
  }
}
