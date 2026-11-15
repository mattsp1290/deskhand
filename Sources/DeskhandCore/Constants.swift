/// The constants of contract section 16. Configured values appear here as their defaults and ranges;
/// the values in force are reported by ``Limits``.
public enum ContractConstants {
    public static let contractVersion = "0.11-draft"
    public static let mcpProtocolVersion = "2026-07-28"

    // Screenshot sizing and encoding (contract 7).
    public static let maxLongEdge = 2576
    public static let minLongEdge = 256
    /// The provider's cap on one image. ``maxPixels`` keeps every output under it whichever way a
    /// provider counts tokens: by area (`w * h / 750`) or by patches (``visualTokenPatchSide``).
    public static let maxVisualTokens = 4784
    /// The side of the square a provider counts as one visual token when it counts by patches.
    public static let visualTokenPatchSide = 28
    /// `MAX_VISUAL_TOKENS * 750`.
    public static let maxPixels = 3_588_000
    /// Measured on the encoded image, before base64: exactly 5,000,000 base64 characters.
    public static let maxImageBytes = 3_750_000
    public static let jpegQualitySteps: [JPEGQuality] = JPEGQuality.allCases

    // Target-patch check (contract 8.4) and the drag's path check (contract 6.9).
    public static let patchSize = 64
    public static let patchChannelTolerance = 16
    public static let patchMaxChangedFraction = 0.02
    /// A patch check older than this when the first event is due ends the call with `stale_frame`.
    public static let patchCheckMaxAgeMs = 250
    /// Largest step, in frame pixels, between two points of a drag whose window owner is checked.
    public static let dragPolicySamplePx = 8

    // Frames, activity and deadlines.
    public static let frameMaxAgeMsRange = 5000...600_000
    public static let defaultFrameMaxAgeMs = 60_000
    public static let userActivityLookbackMs = 3000
    public static let userActivityPollMs = 100
    public static let userActivityAbortMs = 250
    public static let deadlineBoundMs = 1000
    /// How old a copy of the allowance file's contents may be when it answers (contract 14.4).
    public static let allowanceCacheMaxMs = 1000

    // Lease and rate.
    public static let leaseTTLMsRange = 5000...120_000
    public static let defaultLeaseTTLMs = 30_000
    public static let defaultActionsPerMinute = 60

    // Effect arguments.
    public static let keyboardMaxTextLength = 1024
    public static let keyHoldMsRange = 0...5000
    public static let dragDurationMsRange = 50...5000
    public static let defaultDragDurationMs = 500
    public static let dragPointCountRange = 2...32
    public static let scrollDeltaRange = -10_000...10_000
    public static let permittedAppsCountRange = 1...64

    // Operation records.
    public static let defaultOperationRetentionMs = 86_400_000
    public static let defaultOperationMaxRecords = 10_000

    // Transport.
    public static let maxRequestBodyBytes = 65_536
    public static let maxRequestHeaderBytes = 16_384
    /// The largest image as base64 (5,000,000) plus room for the rest of a `screenshot` response.
    public static let maxResponseBodyBytes = 5_400_000
    public static let connectionMaxAgeSeconds = 300
    /// `ttlMs` of `server/discover` and `tools/list`.
    public static let discoveryTTLMs = 300_000
    /// The longest wait between two attempts to bind the listen address.
    public static let bindRetryMs = 5000
}
