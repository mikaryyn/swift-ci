#if os(macOS)
import CryptoKit
import Foundation
import SwiftCI

/// Sends the parts of an IPA to the pre-signed URLs that App Store Connect returned, one part at a time in part-number
/// order, and computes the MD5 of the file while it reads the parts.
///
/// The parts must cover the file in order without gaps, so that the MD5 of the parts is the MD5 of the file. This is
/// checked before any byte is sent. Each part is read from the file once; a retry sends the same bytes. A request carries
/// only the headers of its operation and no `Authorization`, because the URL is pre-signed. The request goes through the
/// registered ``HTTPClient`` directly, not through ``AppStoreConnect``, which would add the token.
struct BuildUploadParts {
    init(ipa: URL, fileSize: Int, now: @escaping () -> Date, sleep: @escaping (Duration) async throws -> Void) {
        self.ipa = ipa
        self.fileSize = fileSize
        self.now = now
        self.sleep = sleep
    }

    @Use private var client: HTTPClient
    @Use private var log: Log
    private let ipa: URL
    private let fileSize: Int
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void

    /// The waits before each retry of a part, in seconds. A part is retried at most once per entry.
    static let retryDelays = [2, 4, 8]

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

    /// Sends the parts of `operations`, which must be in part-number order, and returns the MD5 of the file as lowercase
    /// hexadecimal. Throws a ``BuildError`` when the operations do not cover the file, when a part is refused, or when
    /// the upload took too long.
    func send(_ operations: [UploadOperation]) async throws -> String {
        let parts = try checkedParts(operations)
        let handle = try FileHandle(forReadingFrom: ipa)
        defer { try? handle.close() }

        var md5 = Insecure.MD5()
        var uploaded = 0
        var reportedTenths = 0
        for part in parts {
            try checkNotExpired(part)
            let data = try read(part, from: handle)
            try await put(part, data)
            md5.update(data: data)
            uploaded += data.count
            reportProgress(uploaded: uploaded, reportedTenths: &reportedTenths)
        }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
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

    /// Throws a ``BuildError`` when the expiration of the part has passed. A part is never sent after it.
    private func checkNotExpired(_ part: Part) throws {
        guard let expiration = part.expiration, now() > expiration else { return }
        throw BuildError(message: "The upload took too long: App Store Connect closed the upload of part \(part.number) before it was sent. Run the deploy again to start a new upload.")
    }

    /// The bytes `part.offset..<part.offset + part.length` of the file.
    private func read(_ part: Part, from handle: FileHandle) throws -> Data {
        try handle.seek(toOffset: UInt64(part.offset))
        let data = try handle.read(upToCount: part.length) ?? Data()
        guard data.count == part.length else {
            throw BuildError(message: "The IPA \(ipa.filePath) is shorter than the upload expects. Check that the file was not changed during the upload, then run the step again.")
        }
        return data
    }

    /// Sends `data` as the part, with the method, URL and headers of its operation. A 5xx status or no response is retried
    /// after the waits in ``retryDelays``. Any other status fails at once. Errors name the part and the status, never the
    /// URL, because a pre-signed URL carries credentials.
    private func put(_ part: Part, _ data: Data) async throws {
        let request = HTTPRequest(method: part.method, url: part.url, headers: part.headers, body: data)
        var retries = 0
        while true {
            let response: HTTPResponse? = try? await client.send(request)
            if let response {
                if (200..<300).contains(response.statusCode) {
                    return
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

    /// Logs the progress when it reaches a new tenth of the file, so at most ten lines are logged:
    /// `Uploaded 40% (52.1 MB of 130.2 MB)`.
    private func reportProgress(uploaded: Int, reportedTenths: inout Int) {
        guard fileSize > 0 else { return }
        let tenths = uploaded * 10 / fileSize
        guard tenths > reportedTenths else { return }
        reportedTenths = tenths
        log("Uploaded \(tenths * 10)% (\(Self.size(uploaded)) of \(Self.size(fileSize)))")
    }

    /// A byte count for a console line, such as `52.1 MB`.
    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
#endif
