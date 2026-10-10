import Compression
import Foundation

/// Raw-DEFLATE helpers for launch payload entries.
///
/// The system rejects saved provider configurations above 524,288 bytes
/// ("The configuration is too large"), and magic-protocol subscriptions
/// produce YAML far beyond that. The config therefore travels compressed:
/// libcompression's COMPRESSION_ZLIB is raw DEFLATE (no zlib/gzip framing),
/// written by the main app and decoded symmetrically by the network
/// extension. The decompressed size travels next to the payload because raw
/// DEFLATE carries no length.
public enum PayloadCompression {
  /// Upper bound sanity limit for inflate; nothing legitimate comes close.
  static let maxInflatedSize = 8_000_000

  /// Returns nil when compression fails (incompressible input or buffer
  /// growth exhausted). Callers must keep a fallback path.
  public static func deflate(_ data: Data) -> Data? {
    guard !data.isEmpty else {
      return nil
    }
    for capacity in [data.count + 64, data.count * 2] {
      var destination = Data(count: capacity)
      let written = destination.withUnsafeMutableBytes { destinationBuffer in
        data.withUnsafeBytes { sourceBuffer in
          compression_encode_buffer(
            destinationBuffer.bindMemory(to: UInt8.self).baseAddress!,
            capacity,
            sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
            data.count,
            nil,
            COMPRESSION_ZLIB
          )
        }
      }
      if written > 0 {
        return destination[0..<written]
      }
    }
    return nil
  }

  /// Inflates a raw DEFLATE stream. Returns nil when the stream is corrupt
  /// or does not produce exactly `expectedSize` bytes.
  public static func inflate(_ data: Data, expectedSize: Int) -> Data? {
    guard !data.isEmpty, expectedSize > 0, expectedSize <= maxInflatedSize
    else {
      return nil
    }
    var destination = Data(count: expectedSize)
    let written = destination.withUnsafeMutableBytes { destinationBuffer in
      data.withUnsafeBytes { sourceBuffer in
        compression_decode_buffer(
          destinationBuffer.bindMemory(to: UInt8.self).baseAddress!,
          expectedSize,
          sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
          data.count,
          nil,
          COMPRESSION_ZLIB
        )
      }
    }
    guard written == expectedSize else {
      return nil
    }
    return destination
  }
}
