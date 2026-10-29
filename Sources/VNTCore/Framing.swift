import Foundation

/// Chrome's native messaging framing: a 4-byte little-endian length, then UTF-8 JSON.
/// The app's Unix socket uses the same framing, so the host can relay bytes unchanged.
public enum Framing {
    /// Chrome refuses host-to-extension messages over 1 MB; requests can be larger.
    public static let maxMessage = 64 * 1024 * 1024

    public static func encode(_ object: [String: Any]) -> Data? {
        guard let json = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        var length = UInt32(json.count).littleEndian
        var data = Data(bytes: &length, count: 4)
        data.append(json)
        return data
    }
}

/// Collects bytes from a stream and hands out complete messages.
public struct FrameDecoder {
    private var buffer = Data()

    public init() {}

    /// Bytes received after the last complete message (the start of the next one).
    public var remainder: Data { buffer }

    /// Appends bytes and returns every complete message now available.
    /// Throws if a frame announces an impossible length, which means the stream is corrupt.
    public mutating func append(_ data: Data) throws -> [[String: Any]] {
        buffer.append(data)
        var messages: [[String: Any]] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).withUnsafeBytes { raw in
                raw.loadUnaligned(as: UInt32.self).littleEndian
            }
            guard length <= Framing.maxMessage else { throw FramingError.tooLarge(Int(length)) }
            guard buffer.count >= 4 + Int(length) else { break }
            let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + Int(length))
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 4 + Int(length))
            if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                messages.append(object)
            }
        }
        return messages
    }
}

public enum FramingError: Error {
    case tooLarge(Int)
}
