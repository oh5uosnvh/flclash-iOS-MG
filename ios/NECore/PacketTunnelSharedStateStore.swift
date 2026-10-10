import Foundation

#if canImport(Shared)
import Shared
#endif

enum PacketTunnelEnvironment {
  static let extensionBundleIdentifier = Bundle.main.bundleIdentifier!
  static let baseBundleIdentifier = String(
    extensionBundleIdentifier.dropLast(".NECore".count)
  )
  static let widgetIdentifier = "\(baseBundleIdentifier).Widget"
  static let eventNotificationName =
    "\(extensionBundleIdentifier).event"
}

final class PacketTunnelSharedStateStore {
  private static let emptySetupParams = Data("{}".utf8)

  private let sharedStateKey = "sharedState"
  private let setupParamsKey = "setupParams"
  private let runTimeKey = "runTime"
  private let activeVpnOptionsKey = "activeVpnOptions"

  // Launch payload injected from the provider configuration of the saved
  // VPN profile. Present whenever the main app could build it; lets the
  // extension start without a usable shared container (restricted
  // signing environments).
  private var launchPayload: [String: Any]?

  func attachLaunchPayload(
    _ options: [String: NSObject]?,
    providerConfiguration: [String: Any]? = nil
  ) {
    // App starts pass a flat dictionary. Older builds used an envelope;
    // Settings/On Demand starts may pass no options at all.
    launchPayload = nil
    let candidates: [[String: Any]?] = [
      options?["launchPayload"] as? [String: Any],
      options?.mapValues { $0 as Any },
      providerConfiguration?["launchPayload"] as? [String: Any],
      providerConfiguration,
    ]
    for candidate in candidates {
      guard let payload = candidate,
        (payload["launchPayloadVersion"] as? Int) == 1,
        let rawOptions = payload["vpnOptions"] as? [String: Any],
        let data = try? JSONSerialization.data(withJSONObject: rawOptions),
        (try? JSONDecoder().decode(PacketTunnelVPNOptions.self, from: data)) != nil
      else {
        continue
      }
      launchPayload = payload
      return
    }
  }

  func loadVPNOptionsSnapshot() -> (options: PacketTunnelVPNOptions, data: Data)? {
    if let payload = launchPayload,
      let rawOptions = payload["vpnOptions"] as? [String: Any],
      let data = try? JSONSerialization.data(withJSONObject: rawOptions),
      let options = try? JSONDecoder().decode(PacketTunnelVPNOptions.self, from: data)
    {
      return (options, data)
    }
    guard let sharedData = userDefaults?.data(forKey: sharedStateKey),
      let shared = try? JSONSerialization.jsonObject(with: sharedData) as? [String: Any],
      let rawOptions = shared["vpnOptions"] as? [String: Any],
      let data = try? JSONSerialization.data(withJSONObject: rawOptions),
      let options = try? JSONDecoder().decode(PacketTunnelVPNOptions.self, from: data)
    else {
      return nil
    }
    return (options, data)
  }

  func launchPayloadAvailable() -> Bool {
    launchPayload != nil
  }

  func loadSetupParams() -> Data {
    if let payload = launchPayload,
      let raw = payload["setupParams"],
      !(raw is NSNull),
      JSONSerialization.isValidJSONObject(raw),
      let data = try? JSONSerialization.data(withJSONObject: raw)
    {
      return data
    }
    guard let userDefaults else {
      return Self.emptySetupParams
    }
    if let data = userDefaults.data(forKey: setupParamsKey) {
      return data
    }
    guard let sharedStateData = userDefaults.data(forKey: sharedStateKey),
      let json = try? JSONSerialization.jsonObject(with: sharedStateData)
        as? [String: Any],
      let setupParams = json[setupParamsKey],
      !(setupParams is NSNull),
      JSONSerialization.isValidJSONObject(setupParams),
      let data = try? JSONSerialization.data(withJSONObject: setupParams)
    else {
      return Self.emptySetupParams
    }
    userDefaults.set(data, forKey: setupParamsKey)
    return data
  }

  func makeInitParams() -> String {
    let homeDirectory = homeDirectoryForCore()?.path ?? ""
    return "{\"home-dir\":\"\(homeDirectory)\",\"version\":0}"
  }

  // The shared container is the preferred home: the main app already
  // populated it with the profile config and geo resources. When it is
  // unavailable (restricted signing), the extension falls back to its own
  // sandboxed home, which prepareRuntimeHomeIfNeeded() populates.
  func usesAppGroupHome() -> Bool {
    appGroupDirectory() != nil
  }

  func homeDirectoryForCore() -> URL? {
    if usesAppGroupHome() {
      return appGroupDirectory()
    }
    if launchPayload != nil {
      return sandboxHomeDirectory()
    }
    return appGroupDirectory()
  }

  func appGroupDirectory() -> URL? {
    SharedLocation.resolve()?.container
  }

  func sandboxHomeDirectory() -> URL? {
    let fileManager = FileManager.default
    guard
      let base = fileManager.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else {
      return nil
    }
    let home = base.appendingPathComponent("CoreHome", isDirectory: true)
    try? fileManager.createDirectory(
      at: home, withIntermediateDirectories: true
    )
    return home
  }

  func configYamlDataFromPayload() -> Data? {
    guard let payload = launchPayload else {
      return nil
    }
    // Deflated entries carry the raw DEFLATE stream plus the original size
    // (raw DEFLATE has no length trailer).
    if let deflated = payload["configYamlDeflate"] as? Data,
      let expectedSize = payload["configYamlSize"] as? Int,
      let inflated = PayloadCompression.inflate(deflated, expectedSize: expectedSize),
      !inflated.isEmpty
    {
      return inflated
    }
    guard let configYaml = payload["configYaml"] as? String,
      !configYaml.isEmpty
    else {
      return nil
    }
    return Data(configYaml.utf8)
  }

  /// Copies the read-only geodata shipped inside the NECore.appex resource
  /// bundle into the extension's writable core home. This is intentionally local:
  /// the NE is started before the tunnel exists, so a direct CDN request here
  /// can deadlock startup or hit the Network Extension watchdog.
  @discardableResult
  func copyBundledGeoDataIfNeeded() -> (copied: [String], missing: [String]) {
    guard let home = homeDirectoryForCore() else {
      return ([], ["core-home"])
    }
    let fileManager = FileManager.default
    try? fileManager.createDirectory(at: home, withIntermediateDirectories: true)

    // GeoData is a synchronized resource directory of the NECore target.
    // Keep a flat-resource fallback because Xcode may flatten resources when
    // a generated project is opened by an older build tool.
    let resources = [
      (name: "GeoSite", ext: "dat", destination: "GeoSite.dat"),
      (name: "GeoIP", ext: "metadb", destination: "geoip.metadb"),
      (name: "GeoIP", ext: "dat", destination: "GeoIP.dat"),
      (name: "ASN", ext: "mmdb", destination: "ASN.mmdb"),
      (name: "BundleMRS", ext: "7z", destination: "BundleMRS.7z"),
    ]
    var copied: [String] = []
    var missing: [String] = []

    for resource in resources {
      let destination = home.appendingPathComponent(resource.destination)
      if fileManager.fileExists(atPath: destination.path),
        let values = try? destination.resourceValues(forKeys: [.fileSizeKey]),
        let size = values.fileSize,
        size > 0
      {
        continue
      }
      let source = Bundle.main.url(
        forResource: resource.name,
        withExtension: resource.ext,
        subdirectory: "GeoData"
      ) ?? Bundle.main.url(
        forResource: resource.name,
        withExtension: resource.ext
      )
      guard let source, fileManager.fileExists(atPath: source.path) else {
        missing.append("\(resource.name).\(resource.ext)")
        continue
      }
      let temporary = home.appendingPathComponent(
        ".\(resource.destination).\(UUID().uuidString).tmp"
      )
      do {
        try? fileManager.removeItem(at: temporary)
        try fileManager.copyItem(at: source, to: temporary)
        if fileManager.fileExists(atPath: destination.path) {
          _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
          try fileManager.moveItem(at: temporary, to: destination)
        }
        copied.append(resource.destination)
      } catch {
        try? fileManager.removeItem(at: temporary)
        missing.append("\(resource.name).\(resource.ext)")
      }
    }
    return (copied, missing)
  }

  func saveRunTime(vpnOptions: Data) {
    let milliseconds = Int(Date().timeIntervalSince1970 * 1000)
    userDefaults?.set(vpnOptions, forKey: activeVpnOptionsKey)
    userDefaults?.set(milliseconds, forKey: runTimeKey)
  }

  func clearRunTime() {
    userDefaults?.removeObject(forKey: runTimeKey)
    userDefaults?.removeObject(forKey: activeVpnOptionsKey)
  }

  private var userDefaults: UserDefaults? {
    SharedLocation.defaults()
  }
}

struct PacketTunnelVPNOptions: Decodable {
  let port: Int
  let ipv6: Bool
  let captureDns: Bool
  let systemProxy: Bool
  let bypassDomain: [String]
  let stack: String
  let mtu: Int
  let routeAddress: [String]
  let disableIcmpForwarding: Bool
  let endpointIndependentNat: Bool
  let congestionController: String
  let recvMsgX: Bool
  let sendMsgX: Bool
  let includeAllNetworks: Bool
  let excludeLocalNetworks: Bool
  let excludeAPNs: Bool
  let excludeCellularServices: Bool
  let enforceRoutes: Bool
  let excludeDeviceCommunication: Bool

  private enum CodingKeys: String, CodingKey {
    case port
    case ipv6
    case captureDns
    case systemProxy
    case bypassDomain
    case stack
    case mtu
    case routeAddress
    case disableIcmpForwarding
    case endpointIndependentNat
    case congestionController
    case recvMsgX
    case sendMsgX
    case includeAllNetworks
    case excludeLocalNetworks
    case excludeAPNs
    case excludeCellularServices
    case enforceRoutes
    case excludeDeviceCommunication
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    port = try container.decode(Int.self, forKey: .port)
    ipv6 = try container.decode(Bool.self, forKey: .ipv6)
    captureDns = try container.decode(Bool.self, forKey: .captureDns)
    systemProxy = try container.decode(Bool.self, forKey: .systemProxy)
    bypassDomain = try container.decodeIfPresent(
      [String].self,
      forKey: .bypassDomain
    ) ?? []
    stack = try container.decode(String.self, forKey: .stack)
    mtu = try container.decodeIfPresent(Int.self, forKey: .mtu) ?? 9000
    routeAddress = try container.decodeIfPresent(
      [String].self,
      forKey: .routeAddress
    ) ?? []
    disableIcmpForwarding = try container.decodeIfPresent(
      Bool.self,
      forKey: .disableIcmpForwarding
    ) ?? false
    endpointIndependentNat = try container.decodeIfPresent(
      Bool.self,
      forKey: .endpointIndependentNat
    ) ?? false
    congestionController = try container.decodeIfPresent(
      String.self,
      forKey: .congestionController
    ) ?? ""
    recvMsgX = try container.decodeIfPresent(Bool.self, forKey: .recvMsgX) ?? true
    sendMsgX = try container.decodeIfPresent(Bool.self, forKey: .sendMsgX) ?? false
    includeAllNetworks = try container.decodeIfPresent(
      Bool.self,
      forKey: .includeAllNetworks
    ) ?? false
    excludeLocalNetworks = try container.decodeIfPresent(
      Bool.self,
      forKey: .excludeLocalNetworks
    ) ?? true
    excludeAPNs = try container.decodeIfPresent(
      Bool.self,
      forKey: .excludeAPNs
    ) ?? true
    excludeCellularServices = try container.decodeIfPresent(
      Bool.self,
      forKey: .excludeCellularServices
    ) ?? true
    enforceRoutes = try container.decodeIfPresent(
      Bool.self,
      forKey: .enforceRoutes
    ) ?? false
    excludeDeviceCommunication = try container.decodeIfPresent(
      Bool.self,
      forKey: .excludeDeviceCommunication
    ) ?? true
  }
}
