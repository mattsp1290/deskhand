/// The constants of contract section 16. Configured values appear here as their defaults and ranges;
/// the values in force are reported by ``Limits``.
public enum ContractConstants {
    public static let contractVersion = "0.9-draft"
    public static let mcpProtocolVersion = "2026-07-28"

    // Screenshot sizing and encoding (contract 7).
    public static let maxLongEdge = 2576
    public static let minLongEdge = 256
    public static let maxPixels = 3_750_000
    /// Measured on the encoded image, before base64.
    public static let maxImageBytes = 5_000_000
    public static let jpegQualitySteps: [JPEGQuality] = JPEGQuality.allCases

    // Target-patch check (contract 8.4).
    public static let patchSize = 64
    public static let patchChannelTolerance = 16
    public static let patchMaxChangedFraction = 0.02

    // Frames, activity and deadlines.
    public static let frameMaxAgeMsRange = 5000...600_000
    public static let defaultFrameMaxAgeMs = 60_000
    public static let userActivityLookbackMs = 3000
    public static let userActivityPollMs = 100
    public static let userActivityAbortMs = 250
    public static let deadlineBoundMs = 1000

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
    public static let maxResponseBodyBytes = 7_000_000
    public static let connectionMaxAgeSeconds = 300
}
