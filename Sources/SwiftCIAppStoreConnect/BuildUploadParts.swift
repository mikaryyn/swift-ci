#if os(macOS)
import CryptoKit
import Foundation
import SwiftCI

/// Sends the parts of an IPA to the pre-signed URLs that App Store Connect returned, several at a time, and computes the
/// MD5 of the file once every part has been sent.
///
/// At most `parallelUploads` parts are in flight. The parts are started in part-number order, and the next one starts when
/// one finishes, so the parts can finish in any order. Each part opens its own file handle, so no seek position is shared.
/// The parts must cover the file in order without gaps, so that the MD5 of the parts is the MD5 of the file. This is
/// checked before any byte is sent. A request carries only the headers of its operation and no `Authorization`, because
/// the URL is pre-signed. The request goes through the registered ``HTTPClient`` directly, not through ``AppStoreConnect``,
/// which would add the token.
struct BuildUploadParts {
    init(
        ipa: URL, fileSize: Int, parallelUploads: Int,
        now: @escaping () -> Date, sleep: @escaping (Duration) async throws -> Void
    ) {
        self.ipa = ipa
        self.fileSize = fileSize
        self.parallelUploads = parallelUploads
        self.now = now
        self.sleep = sleep
    }

    @Use private var client: HTTPClient
    @Use private var log: Log
    private let ipa: URL
    private let fileSize: Int
    private let parallelUploads: Int
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void

    /// The waits before each retry of a part, in seconds. A part is retried at most once per entry.
    static let retryDelays = [2, 4, 8]

    /// The size of the chunks in which the file is read for its MD5.
    static let checksumChunkSize = 1 << 20

    /// A part to send: its operation, checked and in order.
    struct Part {
        let number: Int
        let method: String
        let url: URL
        let headers: [String: String]
        let offset: Int
        let length: Int
        let expiration: Date?
    }

    /// A part that was sent: its number, its size, how often it was retried, and how long it took.
    struct SentPart {
        let number: Int
        let size: Int
        let retries: Int
        let seconds: TimeInterval
    }

    /// Sends the parts of `operations`, and returns the MD5 of the file as lowercase hexadecimal. Throws a ``BuildError``
    /// when the operations do not cover the file, when a part is refused, or when the upload took too long. The first part
    /// that fails for good cancels the others, and its error is thrown.
    func send(_ operations: [UploadOperation]) async throws -> String {
        let parts = try checkedParts(operations)
        log("Uploading \(parts.count) parts (\(Self.size(fileSize))) to \(Self.hostList(parts)), \(min(parallelUploads, parts.count)) at a time.")

        let started = now()
        var uploaded = 0
        var reportedTenths = 0
        try await withThrowingTaskGroup(of: SentPart.self) { group in
            var pending = parts.makeIterator()
            for _ in 0..<min(parallelUploads, parts.count) {
                if let part = pending.next() {
                    group.addTask { try await self.sendPart(part) }
                }
            }
            for try await sent in group {
                uploaded += sent.size
                logSent(sent, of: parts.count)
                reportProgress(uploaded: uploaded, elapsed: now().timeIntervalSince(started), reportedTenths: &reportedTenths)
                if let part = pending.next() {
                    group.addTask { try await self.sendPart(part) }
                }
            }
        }

        let checksum = try md5OfFile()
        let seconds = now().timeIntervalSince(started)
        log("Uploaded \(Self.size(fileSize)) in \(Self.seconds(seconds)) s (\(Self.rate(fileSize, seconds: seconds))/s).")
        return checksum
    }

    /// The parts in part-number order. Throws a ``BuildError`` when a part does not start where the one before it ends,
    /// when the parts do not add up to the size of the file, or when a URL is not valid. The error never shows a URL.
    private func checkedParts(_ operations: [UploadOperation]) throws -> [Part] {
        guard !operations.isEmpty else {
            throw BuildError(message: "App Store Connect did not return any upload operations for the IPA. Run the step again; if it repeats, report it with the log.")
        }
        var parts: [Part] = []
        var expectedOffset = 0
        for operation in operations.sorted(by: { $0.partNumber < $1.partNumber }) {
            guard let url = URL(string: operation.url), operation.offset == expectedOffset, operation.length >= 0 else {
                throw BuildError(message: "App Store Connect returned upload operations that do not cover the IPA in order (part \(operation.partNumber)). Run the step again; if it repeats, report it with the log.")
            }
            let headers = Dictionary((operation.requestHeaders ?? []).map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
            parts.append(Part(
                number: operation.partNumber,
                method: operation.method,
                url: url,
                headers: headers,
                offset: operation.offset,
                length: operation.length,
                expiration: expiration(of: operation)
            ))
            expectedOffset += operation.length
        }
        guard expectedOffset == fileSize else {
            throw BuildError(message: "App Store Connect's upload operations cover \(expectedOffset) bytes, but the IPA has \(fileSize) bytes. Run the step again; if it repeats, report it with the log.")
        }
        return parts
    }

    /// The expiration of an operation as a date, or `nil` when it has none. A value that is not an ISO 8601 date is
    /// logged and not checked.
    private func expiration(of operation: UploadOperation) -> Date? {
        guard let text = operation.expiration else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) {
            return date
        }
        log.warning("App Store Connect sent an expiration for part \(operation.partNumber) that is not an ISO 8601 date, so it is not checked.")
        return nil
    }

    /// The hosts of the parts, each once and in order, as the start line names them. A part without a host is shown as
    /// `an unknown host`.
    private static func hostList(_ parts: [Part]) -> String {
        var hosts: [String] = []
        for part in parts {
            let host = part.url.host ?? "an unknown host"
            if !hosts.contains(host) {
                hosts.append(host)
            }
        }
        return hosts.joined(separator: ", ")
    }

    /// Sends one part: checks that it has not expired, reads its bytes, and sends them. Runs as one child task of the group.
    private func sendPart(_ part: Part) async throws -> SentPart {
        try checkNotExpired(part)
        let data = try readPart(part)
        let started = now()
        let retries = try await put(part, data)
        return SentPart(number: part.number, size: data.count, retries: retries, seconds: now().timeIntervalSince(started))
    }

    /// Throws a ``BuildError`` when the expiration of the part has passed. A part is never sent after it.
    private func checkNotExpired(_ part: Part) throws {
        guard let expiration = part.expiration, now() > expiration else { return }
        throw BuildError(message: "The upload took too long: App Store Connect closed the upload of part \(part.number) before it was sent. Run the deploy again to start a new upload.")
    }

    /// The bytes `part.offset..<part.offset + part.length` of the file. The handle belongs to this call, so parts can be read
    /// at the same time.
    private func readPart(_ part: Part) throws -> Data {
        let handle = try FileHandle(forReadingFrom: ipa)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(part.offset))
        let data = try handle.read(upToCount: part.length) ?? Data()
        guard data.count == part.length else {
            throw BuildError(message: "The IPA \(ipa.filePath) is shorter than the upload expects. Check that the file was not changed during the upload, then run the step again.")
        }
        return data
    }

    /// Sends `data` as the part, with the method, URL and headers of its operation, and returns how many times it was retried.
    /// A 5xx status or no response is retried after the waits in ``retryDelays``. Any other status fails at once. Errors name
    /// the part and the status, never the URL, because a pre-signed URL carries credentials.
    private func put(_ part: Part, _ data: Data) async throws -> Int {
        let request = HTTPRequest(method: part.method, url: part.url, headers: part.headers, body: data)
        var retries = 0
        while true {
            try Task.checkCancellation()
            let response: HTTPResponse?
            do {
                response = try await client.send(request)
            } catch {
                // A part cancelled by a failed part of the same upload is not retried.
                try Task.checkCancellation()
                response = nil
            }
            if let response {
                if (200..<300).contains(response.statusCode) {
                    return retries
                }
                guard (500..<600).contains(response.statusCode) else {
                    throw BuildError(message: "Uploading part \(part.number) of the IPA failed with status \(response.statusCode). Run the deploy again to start a new upload.")
                }
            }
            let reason = response.map { "with status \($0.statusCode)" } ?? "without a response"
            guard retries < Self.retryDelays.count else {
                throw BuildError(message: "Uploading part \(part.number) of the IPA failed \(reason) after \(retries) retries. Run the deploy again to start a new upload.")
            }
            let delay = Self.retryDelays[retries]
            log("Uploading part \(part.number) of the IPA failed \(reason); retrying in \(delay) seconds.")
            try await sleep(.seconds(delay))
            retries += 1
        }
    }

    /// Logs a part that was sent: `Part 3/13 (5.2 MB) uploaded in 4.1 s (1.3 MB/s)`, with `after 2 retries` when it was retried.
    private func logSent(_ sent: SentPart, of total: Int) {
        let retries = switch sent.retries {
        case 0: ""
        case 1: " after 1 retry"
        default: " after \(sent.retries) retries"
        }
        log("Part \(sent.number)/\(total) (\(Self.size(sent.size))) uploaded in \(Self.seconds(sent.seconds)) s (\(Self.rate(sent.size, seconds: sent.seconds))/s)\(retries)")
    }

    /// Logs the progress when it reaches a new tenth of the file, so at most ten lines are logged:
    /// `Uploaded 40% (27.1 MB of 67.7 MB) in 35 s, 780 KB/s`. The elapsed time and the rate are those of the whole upload.
    private func reportProgress(uploaded: Int, elapsed: TimeInterval, reportedTenths: inout Int) {
        guard fileSize > 0 else { return }
        let tenths = uploaded * 10 / fileSize
        guard tenths > reportedTenths else { return }
        reportedTenths = tenths
        log("Uploaded \(tenths * 10)% (\(Self.size(uploaded)) of \(Self.size(fileSize))) in \(Int(elapsed.rounded())) s, \(Self.rate(uploaded, seconds: elapsed))/s")
    }

    /// The MD5 of the file as lowercase hexadecimal. The file is read once more, in chunks, after every part was sent.
    private func md5OfFile() throws -> String {
        let handle = try FileHandle(forReadingFrom: ipa)
        defer { try? handle.close() }
        var md5 = Insecure.MD5()
        while let chunk = try handle.read(upToCount: Self.checksumChunkSize), !chunk.isEmpty {
            md5.update(data: chunk)
        }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A byte count for a console line, such as `52.1 MB`.
    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// A transfer rate for a console line, such as `780 KB`. It is `0 bytes` when no time has passed.
    static func rate(_ bytes: Int, seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "0 bytes" }
        return size(Int(Double(bytes) / seconds))
    }

    /// A duration for a console line, with one decimal, such as `4.1`.
    static func seconds(_ seconds: TimeInterval) -> String {
        String(format: "%.1f", seconds)
    }
}
#endif
