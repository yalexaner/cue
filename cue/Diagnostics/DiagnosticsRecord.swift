import Foundation

/// How serious a diagnostics record is.
///
/// Deliberately two cases: the file exists so a failed transfer can be
/// explained after the fact, and a level vocabulary wider than "this is what
/// happened" versus "this is what went wrong" only invites judgement calls at
/// the call site.
enum DiagnosticsLevel: String, Sendable, Equatable {
    case info
    case error
}

/// The subsystem a record belongs to.
///
/// These are the `os_log` categories that already exist in the tree —
/// `downloads` and `storage` — rather than a parallel vocabulary, so a record
/// in the file and a line in the device log can be lined up by eye.
enum DiagnosticsCategory: String, Sendable, Equatable {
    case downloads
    case storage
}

/// One key/value pair on a record.
///
/// The initialisers are the whole point: a caller reaches a `String` value
/// only through `init(_:safe:)`, whose label makes "this text is safe to
/// persist" a conscious claim, while anything URL- or guid-shaped can only
/// arrive already sanitised as a `DiagnosticsHost` or `DiagnosticsGUID`
/// (see `DiagnosticsSafeFields.swift`). Redaction is therefore structural, not
/// a habit each call site has to remember.
struct DiagnosticsField: Sendable, Equatable {
    let key: String
    let value: String

    init(_ key: String, _ host: DiagnosticsHost) {
        self.key = key
        self.value = host.redacted
    }

    init(_ key: String, _ guid: DiagnosticsGUID) {
        self.key = key
        self.value = guid.digest
    }

    init(_ key: String, _ attempt: DiagnosticsAttemptID) {
        self.key = key
        self.value = attempt.value
    }

    init(_ key: String, _ value: Int) {
        self.key = key
        self.value = String(value)
    }

    init(_ key: String, _ value: Int64) {
        self.key = key
        self.value = String(value)
    }

    /// For values that are known-safe by construction — an error domain, a
    /// fixed state name, a build identifier. Never for anything a feed or a
    /// server supplied.
    init(_ key: String, safe value: String) {
        self.key = key
        self.value = value
    }
}

/// The concrete value a `DiagnosticsSink` accepts.
///
/// `event` is a plain `String` here on purpose: the event vocabulary is a
/// separate concern that arrives with the instrumentation, so the record, the
/// formatter and the writer compile and are testable without it.
struct DiagnosticsRecord: Sendable, Equatable {
    let level: DiagnosticsLevel
    let category: DiagnosticsCategory
    let event: String
    let fields: [DiagnosticsField]

    init(
        level: DiagnosticsLevel = .info,
        category: DiagnosticsCategory,
        event: String,
        fields: [DiagnosticsField] = []
    ) {
        self.level = level
        self.category = category
        self.event = event
        self.fields = fields
    }
}
