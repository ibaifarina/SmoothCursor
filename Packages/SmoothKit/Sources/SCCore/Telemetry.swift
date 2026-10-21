import Foundation

/// Cursor and input data recorded alongside the video at ~120 Hz.
/// Positions are in points relative to the capture target, origin top-left.
public struct Telemetry: Hashable, Sendable {
    public struct Header: Codable, Hashable, Sendable {
        /// Capture target size in points.
        public var targetSize: PixelSize
        public var displayScale: Double
        public var cursorSprites: [CursorSprite]
        public init(targetSize: PixelSize, displayScale: Double, cursorSprites: [CursorSprite] = []) {
            self.targetSize = targetSize; self.displayScale = displayScale; self.cursorSprites = cursorSprites
        }
    }

    public struct CursorSprite: Codable, Hashable, Sendable {
        /// Package-relative PNG path.
        public var imageFile: String
        /// Hotspot in points from the top-left of the image.
        public var hotspotX: Double
        public var hotspotY: Double
        /// Image size in points.
        public var width: Double
        public var height: Double
        /// Semantic kind when recognised (arrow, iBeam, pointingHand…), used to map custom packs.
        public var kind: String?
        public init(imageFile: String, hotspotX: Double, hotspotY: Double, width: Double, height: Double, kind: String? = nil) {
            self.imageFile = imageFile; self.hotspotX = hotspotX; self.hotspotY = hotspotY
            self.width = width; self.height = height; self.kind = kind
        }
    }

    public enum Kind: UInt8, Sendable {
        case move = 0, mouseDown, mouseUp, rightDown, rightUp, scroll, keyDown, keyUp
    }

    /// Fixed-size record. `code` = sprite index for moves, key code for keys; `modifiers` = CGEventFlags high bits.
    public struct Event: Hashable, Sendable {
        public var time: Seconds
        public var kind: Kind
        public var x: Float
        public var y: Float
        public var code: UInt16
        public var modifiers: UInt32
        public init(time: Seconds, kind: Kind, x: Float, y: Float, code: UInt16 = 0, modifiers: UInt32 = 0) {
            self.time = time; self.kind = kind; self.x = x; self.y = y; self.code = code; self.modifiers = modifiers
        }
    }

    public var header: Header
    /// Sorted by time.
    public var events: [Event]

    public init(header: Header, events: [Event] = []) {
        self.header = header; self.events = events
    }
}

// MARK: - Binary codec
//
// Layout (little-endian):
//   "SCTL" | u32 version | u32 headerLength | header JSON | u32 eventCount | events…
//   event = f64 time | u8 kind | u8 pad | u16 code | f32 x | f32 y | u32 modifiers  (24 bytes)

public enum TelemetryCodecError: Error { case badMagic, unsupportedVersion(UInt32), truncated }

extension Telemetry {
    static let magic: [UInt8] = Array("SCTL".utf8)
    static let version: UInt32 = 1
    static let eventSize = 24

    public func encoded() throws -> Data {
        var data = Data()
        data.append(contentsOf: Self.magic)
        data.appendLE(Self.version)
        let headerData = try JSONEncoder().encode(header)
        data.appendLE(UInt32(headerData.count))
        data.append(headerData)
        data.appendLE(UInt32(events.count))
        data.reserveCapacity(data.count + events.count * Self.eventSize)
        for e in events {
            data.appendLE(e.time.bitPattern)
            data.append(e.kind.rawValue)
            data.append(0)
            data.appendLE(e.code)
            data.appendLE(e.x.bitPattern)
            data.appendLE(e.y.bitPattern)
            data.appendLE(e.modifiers)
        }
        return data
    }

    public init(decoding data: Data) throws {
        var r = ByteReader(data: data)
        guard try r.bytes(4) == Self.magic else { throw TelemetryCodecError.badMagic }
        let version: UInt32 = try r.read()
        guard version == Self.version else { throw TelemetryCodecError.unsupportedVersion(version) }
        let headerLength: UInt32 = try r.read()
        let header = try JSONDecoder().decode(Header.self, from: Data(try r.bytes(Int(headerLength))))
        let count: UInt32 = try r.read()
        var events: [Event] = []
        events.reserveCapacity(Int(count))
        for _ in 0..<count {
            let time = Double(bitPattern: try r.read())
            let kind = Kind(rawValue: try r.read()) ?? .move
            let _: UInt8 = try r.read()
            let code: UInt16 = try r.read()
            let x = Float(bitPattern: try r.read())
            let y = Float(bitPattern: try r.read())
            let modifiers: UInt32 = try r.read()
            events.append(Event(time: time, kind: kind, x: x, y: y, code: code, modifiers: modifiers))
        }
        self.init(header: header, events: events)
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

private struct ByteReader {
    let data: Data
    var offset = 0

    mutating func bytes(_ n: Int) throws -> [UInt8] {
        guard offset + n <= data.count else { throw TelemetryCodecError.truncated }
        defer { offset += n }
        let start = data.startIndex + offset
        return Array(data[start..<start + n])
    }

    mutating func read<T: FixedWidthInteger>() throws -> T {
        let raw = try bytes(MemoryLayout<T>.size)
        var value: T = 0
        for (i, b) in raw.enumerated() { value |= T(b) << (8 * i) }
        return value
    }
}
