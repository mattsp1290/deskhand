/// The authenticated caller: the client certificate subject. The bearer token is a
/// credential checked per request and is deliberately not part of this identity.
public struct Principal: Hashable, Sendable, CustomStringConvertible {
    public let certificateSubject: String

    public init(certificateSubject: String) {
        self.certificateSubject = certificateSubject
    }

    public var description: String { certificateSubject }
}
