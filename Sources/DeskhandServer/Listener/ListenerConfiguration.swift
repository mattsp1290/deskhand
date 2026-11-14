import DeskhandCore
import NIOCore

/// The `Host` values a request may carry (contract 2.3): `<name>:<service port>` for each configured
/// Service DNS name, and the bare name as well when the service port is 443. Compared after ASCII
/// lowercasing; a value with any non-ASCII byte never matches, and since the configured names are
/// DNS names an IP literal never matches either.
public struct HostAllowlist: Hashable, Sendable {
    private let accepted: Set<[UInt8]>

    public init(names: [String], servicePort: Int) {
        var accepted: Set<[UInt8]> = []
        for name in names {
            guard let lowered = Self.asciiLowercased(name), !lowered.isEmpty else { continue }
            accepted.insert(lowered + Array(":\(servicePort)".utf8))
            if servicePort == 443 { accepted.insert(lowered) }
        }
        self.accepted = accepted
    }

    public init(_ service: ServiceConfig) {
        self.init(names: service.names, servicePort: service.port)
    }

    public func accepts(_ host: String) -> Bool {
        guard let lowered = Self.asciiLowercased(host), !lowered.isEmpty else { return false }
        return accepted.contains(lowered)
    }

    /// Unicode case mapping would let `K` (U+212A KELVIN SIGN) stand for `k`, so only ASCII folds.
    private static func asciiLowercased(_ text: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        for byte in text.utf8 {
            guard byte < 0x80 else { return nil }
            bytes.append((UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte | 0x20 : byte)
        }
        return bytes
    }
}

/// Everything the listener needs. Production builds it from ``DeskhandConfig``; tests use the
/// memberwise initializer to bind loopback, which a validated config never allows.
public struct ListenerConfiguration: Sendable {
    /// An IP literal; production passes ``ListenAddress``'s text.
    public var bindHost: String
    /// 0 binds an ephemeral port (tests).
    public var bindPort: Int
    public var hosts: HostAllowlist
    public var clientCertificates: ClientCertificatePolicy
    public var maxRequestHeaderBytes = ContractConstants.maxRequestHeaderBytes
    public var maxRequestBodyBytes = ContractConstants.maxRequestBodyBytes
    /// `MAX_RESPONSE_BODY_BYTES` (contract 2.5); the listener follows
    /// ``ContractConstants/maxResponseBodyBytes`` rather than keeping a second copy.
    public var maxResponseBodyBytes = ContractConstants.maxResponseBodyBytes
    /// `CONNECTION_MAX_AGE` (contract 2.1).
    public var connectionMaxAge = TimeAmount.seconds(Int64(ContractConstants.connectionMaxAgeSeconds))
    /// A peer that has not finished the TLS handshake by then is disconnected.
    public var handshakeTimeout = TimeAmount.seconds(10)
    /// Once a request head is admitted, its body must be complete within this time, or the
    /// connection closes with no response; no call has started. A body is at most
    /// `MAX_REQUEST_BODY_BYTES` (64 KiB), which takes far less than this on the LAN.
    public var requestBodyTimeout = TimeAmount.seconds(30)
    /// TCP keep-alive on every connection, so a caller that vanishes without a FIN or a reset (a
    /// pod torn down with its network) is noticed while its call runs, and the call is cancelled.
    /// Probing starts after ``keepAliveIdle`` of silence and gives up after ``keepAliveProbes``
    /// unanswered probes ``keepAliveInterval`` apart.
    public var keepAliveIdle = TimeAmount.seconds(60)
    public var keepAliveInterval = TimeAmount.seconds(10)
    public var keepAliveProbes = 3
    /// After deskhand closes its output, how long it waits for the caller to close its side before
    /// closing outright. Request bytes that reach a fully closed socket are answered with a reset,
    /// which can destroy a response the caller has not read yet.
    public var closeLinger = TimeAmount.seconds(2)
    /// D14: how often to retry binding while the LAN address is not on any interface.
    public var bindRetryInterval = TimeAmount.seconds(5)

    public init(bindHost: String, bindPort: Int, hosts: HostAllowlist, clientCertificates: ClientCertificatePolicy) {
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.hosts = hosts
        self.clientCertificates = clientCertificates
    }

    /// The client certificate must carry D11's per-Mac subject, `credentials.client_subject`.
    public init(config: DeskhandConfig) {
        self.init(
            bindHost: config.listen.address.description,
            bindPort: config.listen.port,
            hosts: HostAllowlist(config.service),
            clientCertificates: ClientCertificatePolicy(
                expectedSubject: config.credentials.clientSubject.certificateSubject
            )
        )
    }
}
