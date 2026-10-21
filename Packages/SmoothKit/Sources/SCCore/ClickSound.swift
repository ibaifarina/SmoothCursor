import Foundation

/// The mouse click mixed into exports and played in the preview.
public enum ClickSound {
    public static let sampleRate = 48_000.0

    /// A recorded mouse click, mono at `sampleRate`, starting right at the hit.
    public static let samples: [Float] = {
        let data = Data(base64Encoded: pcm16Base64, options: .ignoreUnknownCharacters) ?? Data()
        return stride(from: 0, to: data.count - 1, by: 2).map { i in
            let value = Int16(bitPattern: UInt16(data[data.startIndex + i]) | UInt16(data[data.startIndex + i + 1]) << 8)
            return Float(value) / Float(Int16.max)
        }
    }()
}
