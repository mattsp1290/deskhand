import Foundation

/// The `openssl` command line the listener tests run. TLS 1.3 session resumption needs OpenSSL 1.1.1
/// or later: LibreSSL, macOS's `/usr/bin/openssl`, issues sessions but never resumes them.
enum OpenSSLTool {
    static let resumptionRequirement =
        "needs OpenSSL 1.1.1 or later (not LibreSSL) on PATH or at /opt/homebrew/bin, /usr/local/bin or "
        + "/opt/homebrew/opt/openssl@3/bin"

    /// The first OpenSSL 1.1.1 or later found on PATH or in Homebrew's usual places, or `nil`.
    static let resuming: URL? = {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates =
            path.split(separator: ":").map { "\($0)/openssl" } + [
                "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl", "/opt/homebrew/opt/openssl@3/bin/openssl",
            ]
        return candidates.lazy.map { URL(fileURLWithPath: $0) }.first(where: isResumingOpenSSL)
    }()

    /// On Linux (CI) the resumption tests always run, so a missing OpenSSL fails them rather than
    /// hiding them.
    static var resumptionTestsEnabled: Bool {
        #if os(Linux)
            true
        #else
            resuming != nil
        #endif
    }

    struct Run {
        let status: Int32
        /// Standard output and standard error, interleaved.
        let output: String
        /// The process ended on a signal, as the timeout's `terminate()` ends it.
        let killed: Bool
    }

    /// Runs the openssl at `url`, by default the resuming OpenSSL when there is one, else whatever
    /// `openssl` PATH names (which can still generate certificates). Writes `input` to its standard
    /// input and closes it, reads its output until it exits, and terminates it after `timeout` seconds.
    static func run(
        _ arguments: [String], input: [UInt8] = [], in directory: URL? = nil, timeout: TimeInterval,
        at url: URL? = nil
    ) throws -> Run {
        let process = Process()
        if let executable = url ?? resuming {
            process.executableURL = executable
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["openssl"] + arguments
        }
        process.currentDirectoryURL = directory
        let stdin = Pipe()
        let output = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = output
        #if canImport(Darwin)
            // A process that already exited must fail the write, not SIGPIPE the test runner. On Linux
            // NIOPosix ignores SIGPIPE for the whole process.
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }
        do {
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
        } catch {
            process.terminate()
            process.waitUntilExit()
            throw error
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return Run(
            status: process.terminationStatus, output: text, killed: process.terminationReason == .uncaughtSignal)
    }

    private static func isResumingOpenSSL(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path),
            let run = try? run(["version"], timeout: 5, at: url), !run.killed, run.status == 0,
            run.output.hasPrefix("OpenSSL ")
        else { return false }
        let version = run.output.dropFirst("OpenSSL ".count).prefix { !$0.isWhitespace }
        let numbers = version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        return numbers.lexicographicallyPrecedes([1, 1, 1]) == false
    }
}
