import Foundation
import os
import Security

/// Unified shared-container resolution for the main app, the network
/// extension, and the widget — without changing entitlements.
///
/// Source-level port of the sideload compatibility behavior recovered from
/// the reference package (round 2 reverse engineering): requests for the
/// *logical* App Group are mapped onto the container this process is
/// actually authorized to use. All processes run the same decision logic,
/// so app/extension state can never split across different roots:
///
///   1. `group.<base bundle id>` while its container opens — unchanged
///      behavior for signing setups that already work.
///   2. otherwise the single other authorized App Group whose container
///      opens (renamed or regenerated groups after re-signing).
///   3. otherwise nil — callers keep their launch-payload and sandbox
///      fallbacks, and diagnostics name the missing piece.
///
/// No private APIs: SecTask mirrors what the system already granted this
/// process, and FileManager answers the same container requests the
/// reference compatibility layer used to swizzle.
enum SharedLocation {
  static let groupPrefix = "group."
  static let fallbackBaseBundleID = "cc.flclash.mg"
  static let entitlementKey = "com.apple.security.application-groups"

  static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? fallbackBaseBundleID,
    category: "SharedLocation"
  )

  // MARK: Logical identifiers

  /// App extensions run with their own bundle id (`<app>.NECore`,
  /// `<app>.Widget`); every process must derive the same logical group.
  static func baseBundleIdentifier(of bundleIdentifier: String) -> String {
    for suffix in [".NECore", ".Widget"] where bundleIdentifier.hasSuffix(suffix) {
      return String(bundleIdentifier.dropLast(suffix.count))
    }
    return bundleIdentifier
  }

  static func logicalGroupID(forBase baseBundleID: String) -> String {
    groupPrefix + baseBundleID
  }

  static var baseBundleID: String {
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? fallbackBaseBundleID
    return baseBundleIdentifier(of: bundleIdentifier)
  }

  static var logicalGroupID: String {
    logicalGroupID(forBase: baseBundleID)
  }

  // MARK: Resolution

  struct Resolution: Equatable {
    let groupID: String
    let container: URL
    let source: String
  }

  /// Pure decision logic, unit-tested in tool/ios/SharedLocationTests.swift.
  /// `container` is injected so tests exercise the policy without a signing
  /// environment. The container answer is the ground truth; the authorized
  /// list only supplies candidates to try after the logical name fails.
  static func pickGroup(
    expected: String,
    authorized: [String],
    container: (String) -> URL?
  ) -> Resolution? {
    if let containerURL = container(expected) {
      return Resolution(
        groupID: expected,
        container: containerURL,
        source: "expected-\(expected)"
      )
    }
    var seen = Set<String>()
    let usable = authorized
      .filter { !$0.isEmpty && $0 != expected }
      .filter { seen.insert($0).inserted }
      .compactMap { groupID -> (String, URL)? in
        container(groupID).map { (groupID, $0) }
      }
    // Multiple usable groups would be a guess; a wrong pick silently splits
    // app and extension state, so refuse and keep the fallbacks instead.
    guard usable.count == 1, let (groupID, containerURL) = usable.first else {
      return nil
    }
    return Resolution(
      groupID: groupID,
      container: containerURL,
      source: "authorized-\(groupID)"
    )
  }

  /// Re-evaluated per call: the calls are cheap, and signing state can only
  /// change by reinstalling the app (a new process).
  static func resolve() -> Resolution? {
    let expected = logicalGroupID
    let authorized = authorizedGroups()
    if let resolution = pickGroup(
      expected: expected,
      authorized: authorized,
      container: defaultContainer
    ) {
      if resolution.source != "expected-\(expected)" {
        logger.notice(
          "mapped logical \(expected, privacy: .public) -> \(resolution.groupID, privacy: .public)"
        )
      }
      return resolution
    }
    if authorized.count > 1 {
      logger.error(
        "ambiguous App Groups \(authorized, privacy: .public); refusing to guess"
      )
    } else {
      logger.notice(
        "no usable App Group container; launch payload and sandbox fallbacks stay active"
      )
    }
    return nil
  }

  /// Group defaults for the container this process can actually use.
  /// Callers already handle nil (no usable container).
  static func defaults() -> UserDefaults? {
    guard let resolution = resolve() else {
      return nil
    }
    return UserDefaults(suiteName: resolution.groupID)
  }

  /// One positive os_log line at startup naming the group in use.
  static func logStartupDiagnostics() {
    guard let resolution = resolve() else {
      return
    }
    logger.notice(
      "shared container ready group=\(resolution.groupID, privacy: .public) source=\(resolution.source, privacy: .public)"
    )
  }

  // MARK: System inputs

  static func authorizedGroups() -> [String] {
    groups(fromEntitlement: entitlementValue())
  }

  /// Entitlement payloads are arrays; some signing paths emit a bare
  /// string. Anything else is unusable, not an empty list to hide.
  static func groups(fromEntitlement raw: Any?) -> [String] {
    if let list = raw as? [Any] {
      return list.compactMap { $0 as? String }
    }
    if let single = raw as? String {
      return [single]
    }
    return []
  }

  private static func entitlementValue() -> Any? {
    guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else {
      logger.error("SecTaskCreateFromSelf failed; cannot inspect groups")
      return nil
    }
    guard let raw = SecTaskCopyValueForEntitlement(
      task, entitlementKey as CFString, nil
    ) else {
      return nil
    }
    return raw as Any
  }

  static func defaultContainer(_ groupID: String) -> URL? {
    FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: groupID
    )
  }
}
