import Foundation

// Compile with ios/Shared/SharedLocation.swift itself:
//   swiftc -swift-version 5 ios/Shared/SharedLocation.swift \
//     tool/ios/SharedLocationTests.swift -o shared_location_tests
@main
struct SharedLocationTests {
  static var failures: [String] = []

  static func check(_ condition: Bool, _ name: String) {
    print("\(condition ? "PASS" : "FAIL") \(name)")
    if !condition {
      failures.append(name)
    }
  }

  static func url(_ path: String) -> URL? {
    URL(fileURLWithPath: path)
  }

  static func main() {
    // Base bundle id derivation (the interrupted draft resolved the NE
    // logical group from the extension bundle id; this is the regression).
    check(
      SharedLocation.baseBundleIdentifier(of: "cc.flclash.mg.NECore") == "cc.flclash.mg",
      "base bundle id strips .NECore"
    )
    check(
      SharedLocation.baseBundleIdentifier(of: "cc.flclash.mg.Widget") == "cc.flclash.mg",
      "base bundle id strips .Widget"
    )
    check(
      SharedLocation.baseBundleIdentifier(of: "cc.flclash.mg") == "cc.flclash.mg",
      "base bundle id keeps app id"
    )
    check(
      SharedLocation.logicalGroupID(forBase: "cc.flclash.mg") == "group.cc.flclash.mg",
      "logical group naming"
    )
    let appLogical = SharedLocation.logicalGroupID(
      forBase: SharedLocation.baseBundleIdentifier(of: "cc.flclash.mg")
    )
    let neLogical = SharedLocation.logicalGroupID(
      forBase: SharedLocation.baseBundleIdentifier(of: "cc.flclash.mg.NECore")
    )
    check(
      appLogical == neLogical,
      "app and extension derive the same logical group"
    )

    // Entitlement payload parsing.
    check(
      SharedLocation.groups(fromEntitlement: ["a", "b"]) == ["a", "b"],
      "array entitlement parsed"
    )
    check(
      SharedLocation.groups(fromEntitlement: "a") == ["a"],
      "bare string entitlement parsed"
    )
    check(
      SharedLocation.groups(fromEntitlement: 42).isEmpty,
      "invalid entitlement rejected"
    )

    let expected = "group.cc.flclash.mg"
    let renamed = "group.team123.flclash"
    let other = "group.other"

    // Policy 1: expected group still wins (working signing unchanged).
    let r1 = SharedLocation.pickGroup(
      expected: expected, authorized: [expected, renamed]
    ) { $0 == expected ? url("/c/expected") : nil }
    check(
      r1?.groupID == expected && r1?.source == "expected-\(expected)",
      "expected group preferred"
    )
    // The container answer is ground truth even if SecTask returned nothing.
    let r2 = SharedLocation.pickGroup(
      expected: expected, authorized: []
    ) { $0 == expected ? url("/c/expected") : nil }
    check(
      r2?.groupID == expected,
      "expected group wins without entitlement list"
    )

    // Policy 2: renamed authorized group is mapped — the fix. A fixed-name
    // implementation returned nil here, so app and extension lost the
    // shared container after re-signing.
    let r3 = SharedLocation.pickGroup(
      expected: expected, authorized: [renamed]
    ) { $0 == renamed ? url("/c/renamed") : nil }
    check(
      r3?.groupID == renamed && r3?.source == "authorized-\(renamed)",
      "renamed authorized group mapped"
    )
    check(
      SharedLocation.pickGroup(
        expected: expected, authorized: ["", renamed]
      ) { $0 == renamed ? url("/c/renamed") : nil }?.groupID == renamed,
      "empty group entries ignored"
    )
    check(
      SharedLocation.pickGroup(
        expected: expected, authorized: [renamed, renamed]
      ) { $0 == renamed ? url("/c/renamed") : nil }?.groupID == renamed,
      "duplicate group entries deduplicated"
    )

    // Policy 3: ambiguous groups refused, fallbacks stay active.
    check(
      SharedLocation.pickGroup(
        expected: expected, authorized: [renamed, other]
      ) { $0 == expected ? nil : url("/c/\($0)") } == nil,
      "ambiguous groups refused"
    )

    // Policy 4: nothing usable keeps payload/sandbox fallbacks.
    check(
      SharedLocation.pickGroup(
        expected: expected, authorized: [renamed]
      ) { _ in nil } == nil,
      "no usable group falls back"
    )
    check(
      SharedLocation.pickGroup(
        expected: expected, authorized: []
      ) { _ in nil } == nil,
      "empty authorization falls back"
    )

    if !failures.isEmpty {
      FileHandle.standardError.write(
        Data("Shared location regressions: \(failures.joined(separator: ", "))\n".utf8)
      )
      exit(1)
    }
    print("Shared location regression suite passed")
  }
}
