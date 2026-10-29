import Foundation

/// The values that must never be written: every registered secret, its percent-encoded forms and its non-empty lines.
///
/// Every writer masks through ``redact(_:)``. The console does it in ``RedactingLog``, and the full log does it in
/// ``FullLog/write(_:)``. The pattern list is built when a value is registered, not on each call.
///
/// This is internal for now. The module split makes the masking function public, with `register` and `Secret`.
/// Tests take a ``snapshot()`` before they change the registry and ``restore(_:)`` it afterwards.
enum SecretRegistry {
    /// What a masked value is replaced with.
    static let mask = "••••••"

    /// Every pattern to mask, the longest first. A secret that contains another one is then masked as a whole.
    private(set) static var patterns: [String] = []
    private static var registered: Set<String> = []

    /// Registers a value, with its percent-encoded forms (upper and lower case hex) and its non-empty lines. An empty
    /// value is ignored. A short value is registered too, so it is never shown.
    static func register(_ value: String) {
        guard !value.isEmpty else { return }
        var texts = [value]
        texts += value.components(separatedBy: .newlines).filter { !$0.isEmpty }
        for text in texts {
            registered.insert(text)
            registered.insert(percentEncoded(text, uppercaseHex: true))
            registered.insert(percentEncoded(text, uppercaseHex: false))
        }
        patterns = registered.sorted { ($0.utf8.count, $0) > ($1.utf8.count, $1) }
    }

    /// Replaces every registered value in `text` with ``mask``.
    static func redact(_ text: String) -> String {
        patterns.reduce(text) { $0.replacingOccurrences(of: $1, with: mask) }
    }

    /// Forgets every registered value.
    static func reset() {
        registered = []
        patterns = []
    }

    /// The registry state, for a test to restore.
    struct State {
        fileprivate let registered: Set<String>
        fileprivate let patterns: [String]
    }

    static func snapshot() -> State {
        State(registered: registered, patterns: patterns)
    }

    static func restore(_ state: State) {
        registered = state.registered
        patterns = state.patterns
    }

    /// Percent-encodes `text` as RFC 3986 does: every byte outside the unreserved set `A–Z a–z 0–9 - . _ ~` is written
    /// as `%XX`. Spaces become `%20`, not `+`.
    static func percentEncoded(_ text: String, uppercaseHex: Bool) -> String {
        let digits = Array(uppercaseHex ? "0123456789ABCDEF" : "0123456789abcdef")
        var result = ""
        for byte in text.utf8 {
            if isUnreserved(byte) {
                result.append(Character(UnicodeScalar(byte)))
            } else {
                result.append("%")
                result.append(digits[Int(byte >> 4)])
                result.append(digits[Int(byte & 0x0F)])
            }
        }
        return result
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
            return true
        default:
            return false
        }
    }
}

/// Wraps a ``Log`` and masks each line before the wrapped log writes it. `register(Log.self, …)` wraps every logger, so no
/// writer receives a registered value. Every requirement of ``Log`` is forwarded with masked strings, so the wrapped
/// log still does its own formatting, colours and full-log writes.
struct RedactingLog: Log {
    let inner: Log

    init(_ inner: Log) {
        self.inner = inner
    }

    func callAsFunction(_ line: String) {
        inner(SecretRegistry.redact(line))
    }

    func completion(_ line: String) {
        inner.completion(SecretRegistry.redact(line))
    }

    func success(_ line: String) {
        inner.success(SecretRegistry.redact(line))
    }

    func warning(_ line: String) {
        inner.warning(SecretRegistry.redact(line))
    }

    func error(_ line: String) {
        inner.error(SecretRegistry.redact(line))
    }

    func enteringStep(name: String, depth: Int) throws {
        try inner.enteringStep(name: SecretRegistry.redact(name), depth: depth)
    }

    func finishedStep(name: String, duration: TimeInterval, depth: Int) throws {
        try inner.finishedStep(name: SecretRegistry.redact(name), duration: duration, depth: depth)
    }

    func failedStep(name: String, depth: Int) throws {
        try inner.failedStep(name: SecretRegistry.redact(name), depth: depth)
    }

    func allowedFailedStep(name: String, depth: Int) throws {
        try inner.allowedFailedStep(name: SecretRegistry.redact(name), depth: depth)
    }

    func skippedStep(name: String, reason: String, depth: Int) throws {
        try inner.skippedStep(name: SecretRegistry.redact(name), reason: SecretRegistry.redact(reason), depth: depth)
    }

    func lines(title: String, lines: String) {
        inner.lines(title: SecretRegistry.redact(title), lines: SecretRegistry.redact(lines))
    }

    func lines(title: String, lines: [String]) {
        inner.lines(title: SecretRegistry.redact(title), lines: lines.map { SecretRegistry.redact($0) })
    }
}
