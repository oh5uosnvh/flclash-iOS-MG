import Foundation
import os

/// Extension-side flight recorder.
///
/// The exported app log only covers the runner process, and `neReport`
/// needs the Go core alive, so anything that kills the NE process before
/// `quickSetup` leaves no trace in the user-visible log. This recorder
/// appends to a plain file in the extension sandbox (no app group, no Go,
/// no shared container required) and trims itself to the last
/// `maxLines` entries.
final class FlightRecorder {
  static let shared = FlightRecorder()

  private let maxLines = 100
  private let queue = DispatchQueue(label: "flight-recorder")
  private var cachedURL: URL?

  static func crashDumpPath() -> String {
    let home = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first?.appendingPathComponent("CoreHome", isDirectory: true)
    return home?.appendingPathComponent("flight.log").path
      ?? NSTemporaryDirectory() + "flight.log"
  }

  private func logFileURL() -> URL {
    if let cachedURL {
      return cachedURL
    }
    let home = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first?.appendingPathComponent("CoreHome", isDirectory: true)
    let url = home?.appendingPathComponent("flight.log")
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("flight.log")
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    cachedURL = url
    return url
  }

  func record(_ message: String) {
    queue.async { [weak self] in
      guard let self else { return }
      let url = self.logFileURL()
      let formatter = DateFormatter()
      formatter.dateFormat = "HH:mm:ss.SSS"
      let line = "\(formatter.string(from: Date())) | \(message)\n"
      if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        handle.write(Data(line.utf8))
      } else {
        try? Data(line.utf8).write(to: url)
      }
      self.trimIfNeeded(url: url)
    }
  }

  func dumpForSystemLog(_ logger: Logger) {
    queue.async { [weak self] in
      guard let self,
        let content = try? String(contentsOf: self.logFileURL(), encoding: .utf8)
      else {
        return
      }
      logger.error("flight log: \(content, privacy: .public)")
    }
  }

  /// Keeps only the newest `maxLines` lines so the file stays a
  /// crash-window ring buffer rather than an unbounded log.
  private func trimIfNeeded(url: URL) {
    guard
      let content = try? String(contentsOf: url, encoding: .utf8)
    else {
      return
    }
    let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
    guard lines.count > maxLines else {
      return
    }
    let kept = lines.suffix(maxLines).joined(separator: "\n") + "\n"
    try? kept.data(using: .utf8)?.write(to: url, options: .atomic)
  }
}
