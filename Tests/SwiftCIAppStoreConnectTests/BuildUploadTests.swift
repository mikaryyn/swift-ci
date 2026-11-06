#if os(macOS)
@testable import SwiftCI
@testable import SwiftCIAppStoreConnect
@testable import SwiftCITestSupport
import CryptoKit
import Foundation
import SwiftCITesting
import Testing

extension GlobalStateTests {
    /// The upload of an IPA: the calls it makes, the parts it sends, the commit, the polls, and what it logs and throws.
    /// The IPA is the committed fixture `MyApp.ipa`, read by a real `unzip`, and the HTTP client is a mock. The waits are
    /// recorded and advance a test clock, so nothing waits.
    @Suite(.serialized) struct BuildUploadTests {
        static let appID = "1234567890"
        static let bundleID = "com.example.myapp"
        static let uploadID = "BUILD-UPLOAD-1"
        static let fileID = "FILE-1"
        static let partOneURL = URL(string: "https://upload.example.com/part-1?X-Amz-Signature=PART-ONE-SIGNATURE")!
        static let partTwoURL = URL(string: "https://upload.example.com/part-2?X-Amz-Signature=PART-TWO-SIGNATURE")!
        static let farFuture = "2999-01-01T00:00:00Z"
        static let startOfClock = Date(timeIntervalSince1970: 1_800_000_000)

        /// The clock of a test. It starts at `startOfClock` and moves by the length of each wait.
        final class TestClock {
            var date = BuildUploadTests.startOfClock
        }

        /// The transport of the PUTs in a test. A part waits until the test releases it, so the test decides how many parts
        /// are in flight at once and in which order they are answered. Requests that are not PUTs go to `mock`.
        final class PartProbe: HTTPClient {
            /// The mock that answers the requests that are not PUTs.
            let mock: HTTPClientMock
            /// The status of the response of each part, by URL. A part without an entry gets 200.
            var statuses: [URL: Int] = [:]
            /// Runs each time a part is answered, so that a test can move its clock.
            var onAnswered: (() -> Void)?
            /// The URLs of the PUTs in the order that they started.
            private(set) var started: [URL] = []
            /// The URLs of the PUTs that were answered, in the order that they were answered. A cancelled part is not here.
            private(set) var answered: [URL] = []
            /// The largest number of PUTs in flight at one time.
            private(set) var maxInFlight = 0
            /// The PUTs that wait for the test to release them.
            private(set) var waiting: [URL] = []
            private var inFlight = 0
            private var released: Set<URL> = []

            init(mock: HTTPClientMock) {
                self.mock = mock
            }

            func send(_ request: HTTPRequest) async throws -> HTTPResponse {
                guard request.method == "PUT" else { return try await mock.send(request) }
                started.append(request.url)
                inFlight += 1
                maxInFlight = max(maxInFlight, inFlight)
                defer { inFlight -= 1 }
                waiting.append(request.url)
                while !released.contains(request.url) {
                    try Task.checkCancellation()
                    await Task.yield()
                }
                answered.append(request.url)
                onAnswered?()
                return HTTPResponse(statusCode: statuses[request.url] ?? 200, headers: [:], body: Data())
            }

            /// Lets the PUT of `url` answer.
            func release(_ url: URL) {
                released.insert(url)
                waiting.removeAll { $0 == url }
            }

            /// Lets every PUT that is waiting now answer.
            func releaseWaiting() {
                for url in waiting {
                    release(url)
                }
            }

            /// Waits until `count` PUTs are waiting. Fails when they do not come within a bounded number of yields.
            func waitUntilWaiting(_ count: Int) async throws {
                try await Self.yieldUntil({ self.waiting.count >= count }, "\(count) parts waiting")
            }

            /// Waits until `count` PUTs have been answered. Fails when they do not come within a bounded number of yields.
            func waitUntilAnswered(_ count: Int) async throws {
                try await Self.yieldUntil({ self.answered.count >= count }, "\(count) parts answered")
            }

            private static func yieldUntil(_ condition: () -> Bool, _ description: String) async throws {
                for _ in 0..<10_000 {
                    if condition() { return }
                    await Task.yield()
                }
                throw BuildError(message: "The test expected \(description), and it did not happen.")
            }
        }

        /// The mocks, recorders and clock of one upload, and the upload itself.
        final class Harness {
            let http = HTTPClientMock()
            let log = LogMock()
            let sleeps = AppStoreConnectTests.SleepRecorder()
            let clock = TestClock()
            var processingTimeout: Duration = .seconds(30 * 60)
            var parallelUploads = 6

            /// Uploads the fixture IPA to `appID` through the HTTP mock of this harness.
            func upload() async throws -> BuildUpload {
                try await upload(over: http)
            }

            /// Uploads the fixture IPA to `appID` through `transport`, with the registrations of this harness.
            func upload(over transport: any HTTPClient) async throws -> BuildUpload {
                let ipa = try GlobalStateTests.IPAInfoTests.fixture("MyApp")
                let client = BuildUploadTests.client(sleeps: sleeps, clock: clock)
                let timeout = processingTimeout
                let parallel = parallelUploads
                return try await BuildUploadTests.withRegistrations(transport, log) {
                    try await client.uploadBuild(
                        ipa: ipa, appID: BuildUploadTests.appID, parallelUploads: parallel, processingTimeout: timeout
                    )
                }
            }

            /// The error that the upload throws, or `nil` if it succeeds.
            func failure() async -> BuildError? {
                await thrownError { _ = try await self.upload() }
            }
        }

        /// The fields of the request bodies that the tests check. Every field is optional, because each body has some.
        struct RequestBody: Decodable {
            struct Resource: Decodable {
                let type: String
                let attributes: Attributes?
                let relationships: Relationships?
            }
            struct Attributes: Decodable {
                let cfBundleShortVersionString: String?
                let cfBundleVersion: String?
                let platform: String?
                let assetType: String?
                let fileName: String?
                let fileSize: Int?
                let uti: String?
                let uploaded: Bool?
                let sourceFileChecksums: Checksums?
            }
            struct Relationships: Decodable {
                let app: Relationship?
                let buildUpload: Relationship?
            }
            struct Relationship: Decodable {
                let data: Identifier
            }
            struct Identifier: Decodable {
                let type: String
                let id: String
            }
            struct Checksums: Decodable {
                let file: Checksum
            }
            struct Checksum: Decodable {
                let algorithm: String
                let hash: String
            }
            let data: Resource
        }

        /// The URL of `path` under the App Store Connect base URL.
        static func url(_ path: String) -> URL {
            AppStoreConnectTests.url(path)
        }

        /// The URL of the app lookup, which asks for the bundle identifier only.
        static var appURL: URL {
            url("/v1/apps/\(appID)?fields%5Bapps%5D=bundleId")
        }

        /// The URL of the upload list that the duplicate check reads for the fixture's version and build.
        static var listURL: URL {
            url("/v1/apps/\(appID)/buildUploads?filter%5BcfBundleShortVersionString%5D=1.2.3&filter%5BcfBundleVersion%5D=42&limit=200")
        }

        /// The bytes of the fixture IPA.
        static func fixtureData() throws -> Data {
            try Data(contentsOf: GlobalStateTests.IPAInfoTests.fixture("MyApp"))
        }

        /// The MD5 of `data` as lowercase hexadecimal.
        static func md5Hex(_ data: Data) -> String {
            Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        /// A client whose waits are recorded, and which advance `clock` by the length of each wait.
        static func client(sleeps: AppStoreConnectTests.SleepRecorder, clock: TestClock) -> AppStoreConnect {
            var appStoreConnect = AppStoreConnectTests.client(sleeps: sleeps)
            appStoreConnect.now = { clock.date }
            appStoreConnect.sleep = { duration in
                sleeps.durations.append(duration)
                clock.date.addTimeInterval(TimeInterval(duration.components.seconds))
            }
            return appStoreConnect
        }

        /// Runs `body` with `transport` and the log mock registered, and the real process runner, which reads the IPA.
        static func withRegistrations<T>(
            _ transport: any HTTPClient, _ log: LogMock, _ body: () async throws -> T
        ) async throws -> T {
            let restore = secretsSetUp()
            defer { restore() }
            registerDependencies()
            register(HTTPClient.self, transport)
            register(Log.self, log)
            return try await body()
        }

        static func json(_ object: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: object)
        }

        static func appBody(bundleID: String = bundleID) throws -> Data {
            try json(["data": ["type": "apps", "id": appID, "attributes": ["bundleId": bundleID]]])
        }

        /// The list of the build uploads of the fixture's version and build, each with its state.
        static func listBody(_ uploads: [(id: String, state: String)], build: String = "42") throws -> Data {
            try json(["data": uploads.map { upload in
                [
                    "type": "buildUploads",
                    "id": upload.id,
                    "attributes": [
                        "cfBundleShortVersionString": "1.2.3",
                        "cfBundleVersion": build,
                        "state": ["state": upload.state],
                    ],
                ] as [String: Any]
            }])
        }

        static func createdBody() throws -> Data {
            try json(["data": [
                "type": "buildUploads",
                "id": uploadID,
                "attributes": ["cfBundleShortVersionString": "1.2.3", "cfBundleVersion": "42", "platform": "IOS"],
            ]])
        }

        static func operationsBody(_ operations: [[String: Any]]) throws -> Data {
            try json(["data": [
                "type": "buildUploadFiles",
                "id": fileID,
                "attributes": ["uploadOperations": operations],
            ]])
        }

        static func buildBody(state: String, errors: [[String: String]] = []) throws -> Data {
            try json(["data": [
                "type": "buildUploads",
                "id": uploadID,
                "attributes": ["state": ["state": state, "errors": errors]],
            ]])
        }

        static func fileBody(state: String, errors: [[String: String]] = []) throws -> Data {
            try json(["data": [
                "type": "buildUploadFiles",
                "id": fileID,
                "attributes": ["assetDeliveryState": ["state": state, "errors": errors]],
            ]])
        }

        /// One upload operation, as App Store Connect sends it.
        static func operation(
            _ number: Int, offset: Int, length: Int, url: URL, headers: [String: String], expiration: String = farFuture
        ) -> [String: Any] {
            [
                "method": "PUT",
                "url": url.absoluteString,
                "offset": offset,
                "length": length,
                "partNumber": number,
                "requestHeaders": headers.sorted { $0.key < $1.key }.map { ["name": $0.key, "value": $0.value] },
                "expiration": expiration,
            ]
        }

        /// The two operations of a file of `size` bytes: its first half, then the rest. The headers of each differ.
        static func twoParts(size: Int, expiration: String = farFuture) -> [[String: Any]] {
            let half = size / 2
            return [
                operation(1, offset: 0, length: half, url: partOneURL, headers: ["x-test-part": "1"], expiration: expiration),
                operation(
                    2, offset: half, length: size - half, url: partTwoURL,
                    headers: ["x-test-part": "2", "x-test-extra": "yes"], expiration: expiration
                ),
            ]
        }

        /// `count` operations that cover a file of `size` bytes in equal parts, the last one with the rest. Each part has its
        /// own pre-signed URL on `upload.example.com`.
        static func operations(count: Int, size: Int) -> [[String: Any]] {
            let length = size / count
            return (0..<count).map { index in
                let number = index + 1
                let offset = index * length
                let partLength = index == count - 1 ? size - offset : length
                let partURL = URL(string: "https://upload.example.com/part-\(number)?X-Amz-Signature=PART-\(number)-SIGNATURE")!
                return operation(number, offset: offset, length: partLength, url: partURL, headers: ["x-test-part": "\(number)"])
            }
        }

        static func queueLookup(_ http: HTTPClientMock, status: Int = 200, bundleID: String = bundleID) throws {
            http.respond("GET", appURL, status: status, body: try appBody(bundleID: bundleID))
        }

        static func queueList(_ http: HTTPClientMock, _ uploads: [(id: String, state: String)] = []) throws {
            http.respond("GET", listURL, body: try listBody(uploads))
        }

        /// Queues an upload from the create to the last read. `partStatuses` gives the statuses of the PUT responses of
        /// each part, in order. `polls` gives the states of the build upload and of its file, one pair per read.
        static func queueUpload(
            _ http: HTTPClientMock,
            size: Int,
            operations: [[String: Any]]? = nil,
            partStatuses: [[Int]] = [[200], [200]],
            polls: [(build: String, file: String)] = [("PROCESSING", "UPLOAD_COMPLETE")]
        ) throws {
            http.respond("POST", url("/v1/buildUploads"), status: 201, body: try createdBody())
            http.respond("POST", url("/v1/buildUploadFiles"), status: 201, body: try operationsBody(operations ?? twoParts(size: size)))
            for (partURL, statuses) in zip([partOneURL, partTwoURL], partStatuses) {
                for status in statuses {
                    http.respond("PUT", partURL, status: status, body: Data())
                }
            }
            http.respond("PATCH", url("/v1/buildUploadFiles/\(fileID)"), body: Data("{}".utf8))
            for poll in polls {
                http.respond("GET", url("/v1/buildUploads/\(uploadID)"), body: try buildBody(state: poll.build))
                http.respond("GET", url("/v1/buildUploadFiles/\(fileID)"), body: try fileBody(state: poll.file))
            }
        }

        static func token(_ http: HTTPClientMock) throws -> String {
            try AppStoreConnectTests.token(of: http.requests[0])
        }

        /// The first request with `method` and `path`, decoded as a JSON:API request body.
        static func requestBody(_ requests: [HTTPClientMock.RecordedRequest], _ method: String, _ path: String) throws -> RequestBody {
            let request = try #require(requests.first { $0.method == method && $0.url.path == path })
            return try JSONDecoder().decode(RequestBody.self, from: try #require(request.body))
        }

        /// Releases the parts of an upload in waves of `cap`, which is how a cap of `cap` parts in flight lets them finish.
        /// Each wave waits until its parts are waiting, then releases them, so a cap that is exceeded releases more parts
        /// at once and the next wave cannot start.
        static func releaseInWaves(_ probe: PartProbe, total: Int, cap: Int) async throws {
            var released = 0
            while released < total {
                let wave = min(cap, total - released)
                try await probe.waitUntilWaiting(wave)
                probe.releaseWaiting()
                released += wave
            }
        }

        /// The status lines of the upload are in the full log as plain text, and the reading of the IPA is explained before
        /// its `unzip` command.
        @Test func statusLinesAreWrittenToTheFullLogAsPlainText() async throws {
            let harness = Harness()
            let data = try Self.fixtureData()
            try Self.queueLookup(harness.http)
            try Self.queueList(harness.http)
            try Self.queueUpload(harness.http, size: data.count)
            var fullLog = ""

            let result = await SwiftCITest.run(["upload"]) {
                command(Command("upload") {
                    _ = try await harness.upload()
                    fullLog = try String(contentsOfFile: #require(FullLog.path).filePath, encoding: .utf8)
                })
            }

            let lines = fullLog.components(separatedBy: "\n")
            let explanation = try #require(lines.firstIndex { $0.hasPrefix("Reading the bundle identifier") })
            let unzip = try #require(lines.firstIndex { $0 == "➤ Command /usr/bin/unzip" })
            #expect(result.exitCode == 0)
            #expect(!fullLog.contains("\u{1B}"))
            #expect(explanation < unzip)
            #expect(lines.contains { $0.hasPrefix("Uploading MyApp.ipa (") && $0.hasSuffix(" as com.example.myapp 1.2.3 (42) to app 1234567890.") })
            #expect(lines.contains("App Store Connect: POST /v1/buildUploads -> 201"))
            #expect(lines.contains { $0.hasPrefix("Part 1/2 (") })
            #expect(lines.contains("✔︎ Uploaded com.example.myapp 1.2.3 (42) to App Store Connect. Processing continues in App Store Connect."))
        }

        /// A successful upload reads the app, lists the uploads of the build, sends two parts, commits and reads the
        /// upload until it is processing. It sends each part with exactly its own headers and the right bytes, and no
        /// `Authorization`. The commit carries the MD5 of the file. No logged line shows the token or the pre-signed URLs.
        @Test func uploadSendsEveryPartAndCommitsTheChecksum() async throws {
            let harness = Harness()
            let data = try Self.fixtureData()
            try Self.queueLookup(harness.http)
            try Self.queueList(harness.http)
            try Self.queueUpload(
                harness.http,
                size: data.count,
                polls: [("AWAITING_UPLOAD", "AWAITING_UPLOAD"), ("PROCESSING", "UPLOAD_COMPLETE")]
            )

            let upload = try await harness.upload()

            #expect(upload == BuildUpload(
                id: Self.uploadID, appID: Self.appID, bundleIdentifier: Self.bundleID, version: "1.2.3", build: "42",
                state: .processing
            ))
            #expect(harness.sleeps.durations == [.seconds(10)])

            let requests = harness.http.requests
            // The parts may finish in either order, so they are compared as a set, by URL.
            #expect(requests.filter { $0.method != "PUT" }.map { "\($0.method) \($0.url.path)" } == [
                "GET /v1/apps/\(Self.appID)",
                "GET /v1/apps/\(Self.appID)/buildUploads",
                "POST /v1/buildUploads",
                "POST /v1/buildUploadFiles",
                "PATCH /v1/buildUploadFiles/\(Self.fileID)",
                "GET /v1/buildUploads/\(Self.uploadID)",
                "GET /v1/buildUploadFiles/\(Self.fileID)",
                "GET /v1/buildUploads/\(Self.uploadID)",
                "GET /v1/buildUploadFiles/\(Self.fileID)",
            ])

            let half = data.count / 2
            let puts = requests.filter { $0.method == "PUT" }
            #expect(puts.count == 2)
            let part1 = try #require(puts.first { $0.url == Self.partOneURL })
            #expect(part1.headers == ["x-test-part": "1"])
            #expect(part1.body == data.subdata(in: 0..<half))
            let part2 = try #require(puts.first { $0.url == Self.partTwoURL })
            #expect(part2.headers == ["x-test-part": "2", "x-test-extra": "yes"])
            #expect(part2.body == data.subdata(in: half..<data.count))
            #expect(puts.allSatisfy { $0.headers["Authorization"] == nil && $0.secretHeaders["Authorization"] == nil })

            let create = try Self.requestBody(requests, "POST", "/v1/buildUploads")
            #expect(create.data.type == "buildUploads")
            #expect(create.data.attributes?.cfBundleShortVersionString == "1.2.3")
            #expect(create.data.attributes?.cfBundleVersion == "42")
            #expect(create.data.attributes?.platform == "IOS")
            #expect(create.data.relationships?.app?.data.id == Self.appID)

            let reserve = try Self.requestBody(requests, "POST", "/v1/buildUploadFiles")
            #expect(reserve.data.attributes?.assetType == "ASSET")
            #expect(reserve.data.attributes?.fileName == "MyApp.ipa")
            #expect(reserve.data.attributes?.fileSize == data.count)
            #expect(reserve.data.attributes?.uti == "com.apple.ipa")
            #expect(reserve.data.relationships?.buildUpload?.data.id == Self.uploadID)

            let commit = try Self.requestBody(requests, "PATCH", "/v1/buildUploadFiles/\(Self.fileID)")
            #expect(commit.data.type == "buildUploadFiles")
            #expect(commit.data.attributes?.uploaded == true)
            #expect(commit.data.attributes?.sourceFileChecksums?.file.algorithm == "MD5")
            #expect(commit.data.attributes?.sourceFileChecksums?.file.hash == Self.md5Hex(data))

            let token = try Self.token(harness.http)
            let lines = harness.log.loggedLines.joined(separator: "\n")
            #expect(lines.contains("Part 1/2 ("))
            #expect(lines.contains("Part 2/2 ("))
            #expect(harness.log.loggedLines.contains { $0.hasSuffix(". 2 of 2 parts done, \(BuildUploadParts.size(data.count)) of \(BuildUploadParts.size(data.count)).") })
            #expect(lines.contains("Created build upload \(Self.uploadID) and file \(Self.fileID)."))
            #expect(lines.contains("App Store Connect: build upload AWAITING_UPLOAD, file AWAITING_UPLOAD"))
            #expect(lines.contains("App Store Connect: build upload PROCESSING, file UPLOAD_COMPLETE"))
            #expect(lines.contains("Uploaded \(Self.bundleID) 1.2.3 (42) to App Store Connect. Processing continues in App Store Connect."))
            #expect(!lines.contains(token))
            #expect(!lines.contains("X-Amz-Signature"))
            #expect(!lines.contains("PART-ONE-SIGNATURE"))
            #expect(!lines.contains("PART-TWO-SIGNATURE"))
        }

        /// The bundle identifier of the app differs from the IPA's: the step fails before it creates anything.
        @Test func bundleIdentifierMismatchFailsBeforeAnyUpload() async throws {
            let harness = Harness()
            try Self.queueLookup(harness.http, bundleID: "com.example.other")

            let error = await harness.failure()

            let message = try #require(error?.message)
            #expect(message.contains("com.example.other"))
            #expect(message.contains(Self.bundleID))
            #expect(message.contains("another app record"))
            #expect(harness.http.requests.count == 1)
        }

        /// A 404 on the app lookup says that no app with the ID is visible to the key.
        @Test func appNotVisibleToTheKeyFailsNamingTheAppID() async throws {
            let harness = Harness()
            try Self.queueLookup(harness.http, status: 404)

            let error = await harness.failure()

            #expect(error?.message.hasPrefix("No app with ID \(Self.appID) is visible to this API key.") == true)
            #expect(harness.http.requests.count == 1)
        }

        /// A build upload of the same version and build that has not failed blocks the upload before any bytes are sent.
        @Test func existingUploadOfTheSameBuildBlocksBeforeAnyBytes() async throws {
            let harness = Harness()
            try Self.queueLookup(harness.http)
            try Self.queueList(harness.http, [(id: "OLD-1", state: "PROCESSING")])

            let error = await harness.failure()

            let message = try #require(error?.message)
            #expect(message.contains("Version 1.2.3 build 42 was already uploaded to app \(Self.appID)"))
            #expect(message.contains("Increase the build number"))
            #expect(harness.http.requests.map(\.method) == ["GET", "GET"])
        }

        /// A failed build upload of the same version and build does not block a new upload.
        @Test func failedUploadOfTheSameBuildDoesNotBlock() async throws {
            let harness = Harness()
            let data = try Self.fixtureData()
            try Self.queueLookup(harness.http)
            try Self.queueList(harness.http, [(id: "OLD-1", state: "FAILED")])
            try Self.queueUpload(harness.http, size: data.count)

            let upload = try await harness.upload()

            #expect(upload.id == Self.uploadID)
            #expect(upload.state == .processing)
        }

        /// A listed build upload of another build number does not block, so a filter that the server ignored cannot block
        /// every upload.
        @Test func uploadOfAnotherBuildDoesNotBlock() async throws {
            let harness = Harness()
            let data = try Self.fixtureData()
            try Self.queueLookup(harness.http)
            harness.http.respond("GET", Self.listURL, body: try Self.listBody([(id: "OLD-1", state: "PROCESSING")], build: "41"))
            try Self.queueUpload(harness.http, size: data.count)

            let upload = try await harness.upload()

            #expect(upload.id == Self.uploadID)
        }

        /// App Store Connect refuses to create a build upload that exists: the error names the build and shows Apple's
        /// details.
        @Test func refusedCreateNamesTheBuildNumberAndShowsAppleDetails() async throws {
            let harness = Harness()
            try Self.queueLookup(harness.http)
            try Self.queueList(harness.http)
            let refusal = try Self.json(["errors": [[
                "status": "409",
                "code": "ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE",
                "title": "A resource with the same value already exists",
                "detail": "The build number 42 already exists.",
            ]]])
            harness.http.respond("POST", Self.url("/v1/buildUploads"), status: 409, body: refusal)

            let error = await harness.failure()

            let message = try #require(error?.message)
            #expect(message.contains("refused to create the build upload of version 1.2.3 build 42"))
            #expect(message.contains("Increase the build number"))
            #expect(message.contains("The build number 42 already exists."))
            #expect(harness.http.requests.count == 3)
        }

        /// A 401 on the first call names the key, and the token is not in the error.
        @Test func unauthorizedOnTheFirstCallNamesTheKey() async throws {
            let harness = Harness()
            try Self.queueLookup(harness.http, status: 401)

            let error = await harness.failure()

            let message = try #require(error?.message)
            #expect(message.contains("rejected the API key for GET /v1/apps/\(Self.appID) (401)"))
            #expect(!message.contains(try Self.token(harness.http)))
            #expect(harness.http.requests.count == 1)
        }

        /// A 429 on the app lookup is retried after one second, and the upload continues.
        @Test func rateLimitOnTheFirstCallIsRetriedAndTheUploadContinues() async throws {
            let harness = Harness()
            let data = try Self.fixtureData()
            harness.http.respond("GET", Self.appURL, status: 429)
            try Self.queueLookup(harness.http)
            try Self.queueList(harness.http)
            try Self.queueUpload(harness.http, size: data.count)

            let upload = try await harness.upload()

            #expect(upload.state == .processing)
            #expect(harness.sleeps.durations == [.seconds(1)])
        }

        /// A part that gets 503 twice is sent again after 2 and 4 seconds, and the third attempt succeeds. The log says how
        /// many retries the part needed.
        @Test func partThatFailsTwiceWithServerErrorIsRetried() async throws {
            let harness = Harness()
            let data = try Self.fixtureData()
            try Self.queueLookup(harness.http)
            try Self.queueList(harness.http)
            try Self.queueUpload(harness.http, size: data.count, partStatuses: [[503, 503, 200], [200]])

            let upload = try await harness.upload()

            #expect(upload.state == .processing)
            #expect(harness.sleeps.durations == [.seconds(2), .seconds(4)])
            #expect(harness.http.requests.filter { $0.method == "PUT" }.count == 4)
            #expect(harness.log.loggedLines.contains { $0.hasPrefix("Part 1/2 (") && $0.contains(" after 2 retries. ") })
        }

        /// One part that gets 403 fails the step with that part's message, at once. The other part is still in flight, so it
        /// is cancelled: it is not answered, nothing is retried, and the file is not committed. No `CancellationError`
        /// escapes, and neither the token nor the pre-signed URL is in the error or the log.
        @Test func partRefusedWithForbiddenCancelsTheOthersAndFailsWithItsMessage() async throws {
            let harness = Harness()
            let data = try Self.fixtureData()
            try Self.queueLookup(harness.http)
            try Self.queueList(harness.http)
            try Self.queueUpload(harness.http, size: data.count, partStatuses: [])
            let probe = PartProbe(mock: harness.http)
            probe.statuses[Self.partOneURL] = 403
            let task = Task { try await harness.upload(over: probe) }

            try await probe.waitUntilWaiting(2)
            probe.release(Self.partOneURL)
            let error = await thrownError { _ = try await task.value }

            let message = try #require(error?.message)
            #expect(message.hasPrefix("Uploading part 1 of the IPA failed with status 403."))
            #expect(probe.started.count == 2)
            #expect(probe.answered == [Self.partOneURL])
            #expect(harness.sleeps.durations.isEmpty)
            #expect(!harness.http.requests.contains { $0.method == "PATCH" })
            let token = try Self.token(harness.http)
            #expect(!message.contains(token))
            #expect(!message.contains("PART-ONE-SIGNATURE"))
            #expect(!message.contains("upload.example.com"))
            #expect(!harness.log.loggedLines.joined().contains(token))
            #expect(!harness.log.loggedLines.joined().contains("X-Amz-Signature"))
        }

        /// The operation's expiry has passed before the first part is sent: the step fails, and no part is sent.
        @Test func expiredOperationFailsBeforeAnyPartIsSent() async throws {
            let harness = Harness()
            let data = try Self.fixtureData()
            try Self.queueLookup(harness.http)
            try Self.queueList(harness.http)
            try Self.queueExpiredReserve(harness.http, size: data.count)

            let error = await harness.failure()

            let message = try #require(error?.message)
            #expect(message.contains("The upload took too long"))
            #expect(message.contains("Run the deploy again to start a new upload."))
            #expect(harness.http.requests.filter { $0.method == "PUT" }.isEmpty)
        }

        /// Queues the create and the reserve of an upload whose operations expired in 2000.
        static func queueExpiredReserve(_ http: HTTPClientMock, size: Int) throws {
            http.respond("POST", url("/v1/buildUploads"), status: 201, body: try createdBody())
            http.respond("POST", url("/v1/buildUploadFiles"), status: 201, body: try operationsBody(
                twoParts(size: size, expiration: "2000-01-01T00:00:00Z")
            ))
        }

        /// A `parallelUploads` below 1 fails before any request is sent, as a usage error.
        @Test func parallelUploadsBelowOneFailsBeforeAnyRequest() async throws {
            let harness = Harness()
            harness.parallelUploads = 0

            let error = await harness.failure()

            #expect(error?.message == "parallelUploads must be at least 1, but it is 0. Pass how many parts to send at the same time, such as 6.")
            #expect(error?.code == .usage)
            #expect(harness.http.requests.isEmpty)
        }

        /// With `parallelUploads` of 2, five parts are sent, and never more than two at the same time.
        @Test func partsInFlightNeverExceedParallelUploads() async throws {
            let harness = Harness()
            harness.parallelUploads = 2
            let data = try Self.fixtureData()
            try Self.queueLookup(harness.http)
            try Self.queueList(harness.http)
            try Self.queueUpload(harness.http, size: data.count, operations: Self.operations(count: 5, size: data.count), partStatuses: [])
            let probe = PartProbe(mock: harness.http)
            let task = Task { try await harness.upload(over: probe) }

            try await Self.releaseInWaves(probe, total: 5, cap: 2)
            _ = try await task.value

            #expect(probe.maxInFlight == 2)
            #expect(probe.started.count == 5)
            #expect(Set(probe.started).count == 5)
            #expect(probe.answered.count == 5)
        }

        /// With the default `parallelUploads` and 13 parts, the parts are sent six at a time: never more than six, and all 13.
        @Test func defaultParallelUploadsKeepsAtMostSixPartsInFlight() async throws {
            let harness = Harness()
            let data = try Self.fixtureData()
            try Self.queueLookup(harness.http)
            try Self.queueList(harness.http)
            try Self.queueUpload(harness.http, size: data.count, operations: Self.operations(count: 13, size: data.count), partStatuses: [])
            let probe = PartProbe(mock: harness.http)
            let task = Task { try await harness.upload(over: probe) }

            try await Self.releaseInWaves(probe, total: 13, cap: 6)
            _ = try await task.value

            #expect(probe.maxInFlight <= 6)
            #expect(probe.maxInFlight == 6)
            #expect(Set(probe.started).count == 13)
            #expect(probe.answered.count == 13)
        }

        /// Parts that finish out of order do not change the checksum: it is still the MD5 of the whole file.
        @Test func checksumIsTheMD5OfTheFileWhenPartsFinishOutOfOrder() async throws {
            let harness = Harness()
            let data = try Self.fixtureData()
            try Self.queueLookup(harness.http)
            try Self.queueList(harness.http)
            try Self.queueUpload(harness.http, size: data.count, partStatuses: [])
            let probe = PartProbe(mock: harness.http)
            let task = Task { try await harness.upload(over: probe) }

            try await probe.waitUntilWaiting(2)
            probe.release(Self.partTwoURL)
            try await probe.waitUntilAnswered(1)
            probe.release(Self.partOneURL)
            _ = try await task.value

            #expect(probe.answered == [Self.partTwoURL, Self.partOneURL])
            let commit = try Self.requestBody(harness.http.requests, "PATCH", "/v1/buildUploadFiles/\(Self.fileID)")
            #expect(commit.data.attributes?.sourceFileChecksums?.file.hash == Self.md5Hex(data))
        }

        /// The start line names the upload host without the query, each part is logged with its size and time, and the
        /// summary is logged at the end. No line shows a pre-signed URL or the token.
        @Test func logNamesTheHostAndEveryPartWithoutTheQuery() async throws {
            let harness = Harness()
            let data = try Self.fixtureData()
            try Self.queueLookup(harness.http)
            try Self.queueList(harness.http)
            try Self.queueUpload(harness.http, size: data.count, partStatuses: [])
            let probe = PartProbe(mock: harness.http)
            probe.onAnswered = { harness.clock.date.addTimeInterval(2) }
            let task = Task { try await harness.upload(over: probe) }

            try await Self.releaseInWaves(probe, total: 2, cap: 6)
            _ = try await task.value

            let lines = harness.log.loggedLines
            let size = BuildUploadParts.size(data.count)
            #expect(lines.contains("Uploading 2 parts (\(size)) to upload.example.com, 2 at a time."))
            #expect(lines.contains { $0.hasPrefix("Part 1/2 (\(BuildUploadParts.size(data.count / 2))) uploaded in ") })
            #expect(lines.contains { $0.hasPrefix("Part 2/2 (\(BuildUploadParts.size(data.count - data.count / 2))) uploaded in ") })
            #expect(lines.contains { $0.hasPrefix("Uploaded \(size) in ") && $0.hasSuffix("/s).") })
            #expect(!lines.contains { $0.hasPrefix("Uploaded ") && $0.contains("%") })

            // The parts finish in either order, so the running totals are checked as a set: the first to finish has its own size,
            // and the last one has both parts.
            let firstSizes = [BuildUploadParts.size(data.count / 2), BuildUploadParts.size(data.count - data.count / 2)]
            #expect(lines.contains { line in firstSizes.contains { line.contains("). 1 of 2 parts done, \($0) of \(size).") } })
            #expect(lines.contains { $0.hasSuffix(". 2 of 2 parts done, \(size) of \(size).") })

            let token = try Self.token(harness.http)
            let output = lines.joined(separator: "\n")
            #expect(!output.contains(token))
            #expect(!output.contains("X-Amz-Signature"))
            #expect(!output.contains("PART-ONE-SIGNATURE"))
            #expect(!output.contains("PART-TWO-SIGNATURE"))
            #expect(!output.contains("upload.example.com/"))
        }

        /// App Store Connect fails the upload: every error of the build and of the file is in the error.
        @Test func failedProcessingListsEveryError() async throws {
            let harness = Harness()
            let data = try Self.fixtureData()
            try Self.queueLookup(harness.http)
            try Self.queueList(harness.http)
            try Self.queueUpload(harness.http, size: data.count, polls: [])
            let buildErrors = [["code": "ERR-A", "description": "Bad binary"], ["code": "ERR-B", "description": "Bad plist"]]
            harness.http.respond("GET", Self.url("/v1/buildUploads/\(Self.uploadID)"), body: try Self.buildBody(state: "FAILED", errors: buildErrors))
            harness.http.respond("GET", Self.url("/v1/buildUploadFiles/\(Self.fileID)"), body: try Self.fileBody(
                state: "FAILED", errors: [["code": "ERR-C", "description": "Missing icon"]]
            ))

            let error = await harness.failure()

            let message = try #require(error?.message)
            #expect(message.contains("ERR-A: Bad binary"))
            #expect(message.contains("ERR-B: Bad plist"))
            #expect(message.contains("ERR-C: Missing icon"))
            #expect(!message.contains("Increase the build number"))
        }

        /// A failure with code 90189 names the build number as one to increase.
        @Test func failureWith90189AsksForAHigherBuildNumber() async throws {
            let harness = Harness()
            let data = try Self.fixtureData()
            try Self.queueLookup(harness.http)
            try Self.queueList(harness.http)
            try Self.queueUpload(harness.http, size: data.count, polls: [])
            harness.http.respond("GET", Self.url("/v1/buildUploads/\(Self.uploadID)"), body: try Self.buildBody(
                state: "FAILED", errors: [["code": "90189", "description": "The build number was used before."]]
            ))
            harness.http.respond("GET", Self.url("/v1/buildUploadFiles/\(Self.fileID)"), body: try Self.fileBody(state: "AWAITING_UPLOAD"))

            let error = await harness.failure()

            #expect(error?.message.contains("90189: The build number was used before.") == true)
            #expect(error?.message.contains("Increase the build number") == true)
        }

        /// Polling reads the upload until the timeout passes, and the error names the last states.
        @Test func processingTimeoutNamesTheLastStates() async throws {
            let harness = Harness()
            harness.processingTimeout = .seconds(30)
            let data = try Self.fixtureData()
            try Self.queueLookup(harness.http)
            try Self.queueList(harness.http)
            try Self.queueUpload(
                harness.http,
                size: data.count,
                polls: Array(repeating: (build: "AWAITING_UPLOAD", file: "AWAITING_UPLOAD"), count: 4)
            )

            let error = await harness.failure()

            let message = try #require(error?.message)
            #expect(message.contains("did not accept the uploaded file within 30 seconds"))
            #expect(message.contains("build upload AWAITING_UPLOAD, file AWAITING_UPLOAD"))
            #expect(harness.sleeps.durations == [.seconds(10), .seconds(10), .seconds(10)])
            #expect(harness.http.requests.filter { $0.method == "GET" && $0.url.path.hasPrefix("/v1/buildUploads/") }.count == 4)
        }

        /// A state that this version does not know is logged, and the upload keeps polling until it is accepted.
        @Test func unknownStateIsLoggedAndPollingContinues() async throws {
            let harness = Harness()
            let data = try Self.fixtureData()
            try Self.queueLookup(harness.http)
            try Self.queueList(harness.http)
            try Self.queueUpload(
                harness.http,
                size: data.count,
                polls: [("SOMETHING_NEW", "UPLOAD_COMPLETE"), ("COMPLETE", "COMPLETE")]
            )

            let upload = try await harness.upload()

            #expect(upload.state == .complete)
            #expect(harness.sleeps.durations == [.seconds(10)])
            #expect(harness.log.loggedLines.joined().contains("build upload SOMETHING_NEW, file UPLOAD_COMPLETE"))
        }
    }
}
#endif
