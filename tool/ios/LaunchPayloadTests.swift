import Foundation

// Compile with PacketTunnelSharedStateStore.swift itself, not a port/model.
@main
struct LaunchPayloadTests {
  static func main() throws {
    let vpn: [String: Any] = [
      "port": 7890, "ipv6": false, "captureDns": true,
      "systemProxy": false, "stack": "gvisor", "mtu": 1400,
    ]
    let payload: [String: Any] = [
      "launchPayloadVersion": 1, "vpnOptions": vpn,
      "setupParams": ["selected-map": ["GLOBAL": "DIRECT"]],
      "configYaml": "mixed-port: 7890\nproxies: []\n",
    ]
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) {
      print("\(condition ? "PASS" : "FAIL") \(name)")
      if !condition { failures.append(name) }
    }
    let direct = PacketTunnelSharedStateStore()
    direct.attachLaunchPayload(payload as? [String: NSObject])
    check(direct.launchPayloadAvailable(), "flat app start options")
    if direct.launchPayloadAvailable() {
      check(direct.loadVPNOptionsSnapshot()?.options.mtu == 1400, "VPN options decoded")
      check(direct.configYamlDataFromPayload() == Data("mixed-port: 7890\nproxies: []\n".utf8), "YAML exact bytes")
      let setup = try JSONSerialization.jsonObject(with: direct.loadSetupParams()) as? [String: Any]
      check(setup?["selected-map"] != nil, "setup params forwarded")
    }
    let legacy = PacketTunnelSharedStateStore()
    legacy.attachLaunchPayload(["launchPayload": payload as NSDictionary])
    check(legacy.launchPayloadAvailable(), "nested legacy options")
    let invalid = PacketTunnelSharedStateStore()
    invalid.attachLaunchPayload(["launchPayloadVersion": NSNumber(value: 2), "vpnOptions": vpn as NSDictionary])
    check(!invalid.launchPayloadAvailable(), "reject unknown version")
    #if PROVIDER_CONFIGURATION_FALLBACK
    let system = PacketTunnelSharedStateStore()
    system.attachLaunchPayload(nil, providerConfiguration: payload)
    check(system.launchPayloadAvailable(), "settings and On Demand without options")
    let fallback = PacketTunnelSharedStateStore()
    fallback.attachLaunchPayload(["launchPayloadVersion": NSNumber(value: 99)], providerConfiguration: payload)
    check(fallback.launchPayloadAvailable(), "invalid options fallback to saved provider configuration")
    direct.attachLaunchPayload(nil, providerConfiguration: nil)
    check(!direct.launchPayloadAvailable(), "no stale payload after repeated start")
    #endif

    // Compressed config payload: raw DEFLATE round-trip and the extension
    // store's decode path (the 524,288-byte provider configuration limit).
    // Only compiled into the after-build; the negative control has no
    // PayloadCompression module.
    #if PAYLOAD_COMPRESSION
    let yamlText = "mixed-port: 7890\nproxies: []\n"
    let yamlData = Data(yamlText.utf8)
    if let deflated = PayloadCompression.deflate(yamlData) {
      check(true, "deflate produced output")
      check(
        PayloadCompression.inflate(deflated, expectedSize: yamlData.count) == yamlData,
        "inflate restores exact bytes"
      )
    } else {
      check(false, "deflate produced output")
    }
    check(
      PayloadCompression.inflate(Data([0x01, 0x02, 0x03]), expectedSize: 16) == nil,
      "inflate rejects junk"
    )
    let repeated = Data(String(repeating: yamlText, count: 4000).utf8)
    if let bigDeflated = PayloadCompression.deflate(repeated) {
      check(
        bigDeflated.count < repeated.count / 2,
        "deflate shrinks repetitive YAML"
      )
      let restored = PacketTunnelSharedStateStore()
      restored.attachLaunchPayload([
        "launchPayloadVersion": NSNumber(value: 1),
        "vpnOptions": vpn as NSDictionary,
        "configYamlDeflate": NSData(data: bigDeflated),
        "configYamlSize": NSNumber(value: repeated.count),
      ] as [String: NSObject])
      check(
        restored.configYamlDataFromPayload() == repeated,
        "extension restores deflated config from payload"
      )
    } else {
      check(false, "deflate shrinks repetitive YAML")
    }
    #endif
    if !failures.isEmpty {
      FileHandle.standardError.write(Data("Launch payload regressions: \(failures.joined(separator: ", "))\n".utf8))
      exit(1)
    }
    print("Launch payload regression suite passed")
  }
}
