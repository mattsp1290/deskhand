/// Who a frame belongs to (contract 4). Under any other scope the frame does not exist.
public struct FrameScope: Hashable, Sendable {
    public let principal: Principal
    public let holderID: HolderID

    public init(principal: Principal, holderID: HolderID) {
        self.principal = principal
        self.holderID = holderID
    }
}

/// What a successful capture hands the store. The store mints the ``FrameID``.
public struct FrameCapture: Sendable {
    public var displayID: DisplayID
    public var displayConfigGeneration: DisplayConfigGeneration
    public var geometry: FrameGeometry
    /// Native pixels of `geometry.captureRect`.
    public var sourcePixelSize: PixelSize
    /// Native pixels per point.
    public var pointPixelScale: Double
    /// In (0, 1].
    public var downscale: Double
    public var capturedAt: Timestamp
    /// `FRAME_MAX_AGE_MS` in force at capture, 5,000 to 600,000.
    public var maxAgeMs: Int
    public var frontmostApp: AppRef
    /// Of size `geometry.outputPixelSize`.
    public var pixels: FramePixels

    public init(
        displayID: DisplayID, displayConfigGeneration: DisplayConfigGeneration, geometry: FrameGeometry,
        sourcePixelSize: PixelSize, pointPixelScale: Double, downscale: Double, capturedAt: Timestamp,
        maxAgeMs: Int, frontmostApp: AppRef, pixels: FramePixels
    ) {
        self.displayID = displayID
        self.displayConfigGeneration = displayConfigGeneration
        self.geometry = geometry
        self.sourcePixelSize = sourcePixelSize
        self.pointPixelScale = pointPixelScale
        self.downscale = downscale
        self.capturedAt = capturedAt
        self.maxAgeMs = maxAgeMs
        self.frontmostApp = frontmostApp
        self.pixels = pixels
    }

    var isConsistent: Bool {
        pixels.size == geometry.outputPixelSize && sourcePixelSize.width >= 1 && sourcePixelSize.height >= 1
            && pointPixelScale.isFinite && pointPixelScale > 0 && downscale > 0 && downscale <= 1
            && ContractConstants.frameMaxAgeMsRange.contains(maxAgeMs)
    }
}

/// The record of one screenshot (contract 4.2, 6.3): everything staleness and mapping need, without
/// the pixels.
public struct Frame: Hashable, Sendable {
    public let id: FrameID
    public let scope: FrameScope
    public let displayID: DisplayID
    public let displayConfigGeneration: DisplayConfigGeneration
    public let geometry: FrameGeometry
    public let sourcePixelSize: PixelSize
    public let pointPixelScale: Double
    public let downscale: Double
    public let capturedAt: Timestamp
    public let maxAgeMs: Int
    public let frontmostApp: AppRef

    init(id: FrameID, scope: FrameScope, capture: FrameCapture) {
        self.id = id
        self.scope = scope
        displayID = capture.displayID
        displayConfigGeneration = capture.displayConfigGeneration
        geometry = capture.geometry
        sourcePixelSize = capture.sourcePixelSize
        pointPixelScale = capture.pointPixelScale
        downscale = capture.downscale
        capturedAt = capture.capturedAt
        maxAgeMs = capture.maxAgeMs
        frontmostApp = capture.frontmostApp
    }

    public var captureRect: GlobalRect { geometry.captureRect }
    public var outputPixelSize: PixelSize { geometry.outputPixelSize }

    /// More than `maxAgeMs` has passed since `capturedAt` (contract 8.3). A `now` before `capturedAt`
    /// means the wall clock stepped back, and the frame's age is then unknowable, so it counts as too old.
    public func isTooOld(at now: Timestamp) -> Bool {
        let age = now.millisecondsSinceEpoch - capturedAt.millisecondsSinceEpoch
        return age < 0 || age > Int64(maxAgeMs)
    }
}

/// A frame that is still the latest for its (principal, `holder_id`, `display_id`), with its pixels.
public struct LiveFrame: Sendable {
    public let frame: Frame
    public let pixels: FramePixels
}

/// What an effect call uses a frame for; `keyboard` adds the frontmost-app check (contract 8.3).
public enum FrameUse: Hashable, Sendable {
    case pointer
    /// `nil` when the frontmost app could not be measured; the frame is then refused as
    /// `frontmost_changed`, failing closed.
    case keyboard(frontmostApp: AppRef?)
}

extension FrameID {
    public static let mintedPrefix = "frm_"

    /// `frm_` and 22 base64url characters carrying 128 bits from `generator` (contract 4.2). Use a
    /// cryptographically secure generator such as `SystemRandomNumberGenerator`: the ID must be unguessable.
    public static func mint(using generator: inout some RandomNumberGenerator) -> FrameID {
        let words = [generator.next() as UInt64, generator.next() as UInt64]
        let bytes = words.flatMap { word in (0..<8).map { UInt8(truncatingIfNeeded: word >> (56 - 8 * $0)) } }
        return FrameID(mintedPrefix + base64URL(bytes))!
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    /// Unpadded RFC 4648 section 5.
    private static func base64URL(_ bytes: [UInt8]) -> String {
        var output: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let chunk = bytes[index..<min(index + 3, bytes.count)]
            let value = chunk.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (16 - 8 * $1.offset) }
            for sextet in 0...chunk.count {
                output.append(alphabet[Int(value >> (18 - 6 * sextet) & 0x3F)])
            }
            index += 3
        }
        return String(decoding: output, as: UTF8.self)
    }
}
