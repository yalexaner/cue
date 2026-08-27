import CryptoKit
import Foundation

/// The most of an address a diagnostics record may carry: scheme and host.
///
/// A private feed's URL *is* its credential (spec §6), and an enclosure URL is
/// pre-signed, so nothing below the host may be persisted. The only
/// initialiser takes the raw text and sanitises it through `redactedAddress(_:)`
/// — the same trimming the alerts use — which means a call site cannot pass a
/// full address where a host is expected, whatever it was holding.
struct DiagnosticsHost: Sendable, Equatable, Hashable {
    /// Bounded like every other field in this file. A host arrives from a feed —
    /// an enclosure URL reaches here — so an unbounded one lets a hostile feed
    /// put kilobytes on a single line. The same bound a sanitised error domain
    /// gets, reused rather than restated: one limit for the text fields, not two.
    static let maximumLength = DiagnosticsErrorCode.maximumDomainLength

    let redacted: String

    init(_ urlString: String) {
        self.redacted = String(redactedAddress(urlString).prefix(Self.maximumLength))
    }
}

/// A guid as a truncated SHA-256 digest of its UTF-8 bytes.
///
/// Never a prefix of the guid itself: a guid is feed-supplied and frequently a
/// URL, so its leading bytes can be a credential. Never Swift's `Hasher`
/// either — that is seeded per process, and the whole reason this file survives
/// relaunch is so a transfer can be followed across one.
struct DiagnosticsGUID: Sendable, Equatable, Hashable {
    /// 16 hex characters — 64 bits, enough to correlate a handful of transfers
    /// in one log without carrying a full digest on every line.
    static let digestLength = 16

    let digest: String

    init(_ guid: String) {
        let hash = SHA256.hash(data: Data(guid.utf8))
        self.digest = String(hash.map { String(format: "%02x", $0) }.joined().prefix(Self.digestLength))
    }
}

/// A live attempt's correlation identifier, derived from the ownership token it
/// already has.
///
/// The token rather than an ordinal counter (there is none) and rather than the
/// background task identifier (iOS reuses those within a session, so two
/// transfers in one log would share a name). A UUID carries nothing private, so
/// this truncates rather than digests — the point is a short handle that lines
/// up "started" with the terminal record that answers it.
struct DiagnosticsAttemptID: Sendable, Equatable, Hashable {
    /// 12 hex characters: long enough that two attempts in one log collide only
    /// by accident, short enough to read down a column.
    static let length = 12

    let value: String

    init(token: UUID) {
        self.value = String(token.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(Self.length))
    }
}

/// An error reduced to the two fields that are safe to persist.
///
/// Never `localizedDescription`, and never the error's own text: a
/// `DownloadManager.Failure.httpStatus` carries an enclosure URL, and a
/// `CocoaError` carries a container path. The bridged `NSError` domain and code
/// carry neither — a Swift error enum bridges to its mangled type name and the
/// case's index, with no associated value — and the domain is sanitised anyway
/// so a custom `NSError` cannot smuggle text through it.
struct DiagnosticsErrorCode: Sendable, Equatable, Hashable {
    /// Bounded so a hostile domain cannot dominate a line.
    static let maximumDomainLength = 64

    let domain: String
    let code: Int

    init(_ error: Error) {
        let bridged = error as NSError
        self.domain = Self.sanitised(bridged.domain)
        self.code = bridged.code
    }

    /// Identifier-shaped characters only; anything else becomes `_`.
    private static func sanitised(_ domain: String) -> String {
        let allowed = domain.unicodeScalars.map { scalar -> Character in
            let isASCIILetterOrDigit =
                (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9")
            if isASCIILetterOrDigit || scalar == "." || scalar == "-" || scalar == "_" {
                return Character(scalar)
            }
            return "_"
        }
        let text = String(allowed.prefix(maximumDomainLength))
        return text.isEmpty ? "unknown" : text
    }
}
