import DeskhandCore

/// SplitMix64: a deterministic generator so minted IDs are reproducible in tests.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Replays fixed words, then zeros.
struct ScriptedGenerator: RandomNumberGenerator {
    var words: [UInt64]

    mutating func next() -> UInt64 { words.isEmpty ? 0 : words.removeFirst() }
}

enum FrameFixtures {
    static let crew = Principal(certificateSubject: "CN=crew-executor")
    static let other = Principal(certificateSubject: "CN=someone-else")
    static let alpha = FrameScope(principal: crew, holderID: HolderID("crew:alpha")!)
    static let beta = FrameScope(principal: crew, holderID: HolderID("crew:beta")!)
    static let alphaOfOther = FrameScope(principal: other, holderID: HolderID("crew:alpha")!)
    static let textEdit = AppRef(bundleID: "com.apple.TextEdit", teamID: nil, name: "TextEdit")
    static let finder = AppRef(bundleID: "com.apple.finder", teamID: nil, name: "Finder")
    static let mainDisplay = DisplayID(1)
    static let sideDisplay = DisplayID(2)
    static let generation = DisplayConfigGeneration(7)
    static let t0 = Timestamp(millisecondsSinceEpoch: 1_800_000_000_000)

    static func geometry(
        _ rect: GlobalRect, _ size: PixelSize, display: GlobalRect? = nil
    ) -> FrameGeometry {
        FrameGeometry(captureRect: rect, outputPixelSize: size, displayBounds: display ?? rect)!
    }

    static func pixels(_ size: PixelSize, fill: UInt8 = 128) -> FramePixels {
        FramePixels(size: size, rgb: Array(repeating: fill, count: size.width * size.height * 3))!
    }

    static func capture(
        display: DisplayID = mainDisplay, generation: DisplayConfigGeneration = generation, at time: Timestamp = t0,
        maxAgeMs: Int = 60_000, frontmost: AppRef = textEdit, size: PixelSize = PixelSize(width: 4, height: 4)
    ) -> FrameCapture {
        let rect = GlobalRect(x: 0, y: 0, width: Double(size.width), height: Double(size.height))
        return FrameCapture(
            displayID: display, displayConfigGeneration: generation, geometry: geometry(rect, size),
            sourcePixelSize: size, pointPixelScale: 2, downscale: 1, capturedAt: time, maxAgeMs: maxAgeMs,
            frontmostApp: frontmost, sha256: SHA256Hex(hashing: Array("image at \(time)".utf8)), pixels: pixels(size))
    }

    static func pointer(_ action: JSONValue) throws -> PointerAction {
        let arguments: JSONObject = [
            "holder_id": "crew:alpha", "frame_id": "frm_x", "operation_id": "op-1", "action": action,
        ]
        return try PointerArguments(arguments: arguments).action
    }
}

extension FrameStore {
    mutating func take(
        _ capture: FrameCapture, for scope: FrameScope, leaseHolder: FrameScope? = nil, now: Timestamp? = nil,
        seed: UInt64 = 1
    ) throws -> Frame {
        var generator = SeededGenerator(state: seed &+ UInt64(liveFrameCount + supersededFrameCount))
        return try record(
            capture, for: scope, leaseHolder: leaseHolder, startedIn: epoch, now: now ?? capture.capturedAt,
            using: &generator)
    }

    /// The `stale_frame` reason `validate` gives, or `nil` when the frame is valid.
    func reason(
        _ id: FrameID, in scope: FrameScope, for use: FrameUse = .pointer,
        generation: DisplayConfigGeneration = FrameFixtures.generation, now: Timestamp = FrameFixtures.t0
    ) -> StaleFrameReason? {
        validate(id, in: scope, for: use, displayConfigGeneration: generation, now: now).reason
    }
}

extension FrameValidation {
    var reason: StaleFrameReason? {
        guard case .stale(let reason) = self else { return nil }
        return reason
    }

    var frame: Frame? {
        guard case .valid(let live) = self else { return nil }
        return live.frame
    }
}
