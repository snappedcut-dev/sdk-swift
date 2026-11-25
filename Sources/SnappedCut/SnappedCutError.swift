import Foundation

/// A refusal from the server, with its status.
///
/// A distinct type because the two failures callers actually branch on --
/// "no credits" (402) and "slow down" (429) -- are not exceptional and should be
/// matched without parsing a message. A status of 0 means the server was never
/// reached, which is the one case worth sending again.
public struct SnappedCutError: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public let status: Int
    public let retryAfterMs: Int
    /// On a 409 from a chunked upload: the byte the server's copy ends at.
    public let expected: Int
    /// The body's machine-readable `code`, when the server sent one.
    public let code: String?

    public init(message: String, status: Int, retryAfterMs: Int = 0, expected: Int = 0,
                code: String? = nil) {
        self.message = message
        self.status = status
        self.retryAfterMs = retryAfterMs
        self.expected = expected
        self.code = code
    }

    public var errorDescription: String? { "\(message) (status \(status))" }

    public var outOfCredits: Bool { status == 402 }
    public var rateLimited: Bool { status == 429 }
    /// The names every Snapped Cut SDK uses.
    public var isOutOfCredits: Bool { outOfCredits }
    public var isRateLimited: Bool { rateLimited }
    /// Never reached the server.
    public var unreachable: Bool { status == 0 }
}
