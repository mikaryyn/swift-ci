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

        /// The mocks, recorders and clock of one upload, and the upload itself.
        final class Harness {
            let http = HTTPClientMock()
            let log = LogMock()
            let sleeps = AppStoreConnectTests.SleepRecorder()
            let clock = TestClock()
            var processingTimeout: Duration = .seconds(30 * 60)

            /// Uploads the fixture IPA to `appID` with the registrations of this harness.
            func upload() async throws -> BuildUpload {
                let ipa = try GlobalStateTests.IPAInfoTests.fixture("MyApp")
                let client = BuildUploadTests.client(sleeps: sleeps, clock: clock)
                let timeout = processingTimeout
                return try await BuildUploadTests.withRegistrations(http, log) {
                    try await client.uploadBuild(ipa: ipa, appID: BuildUploadTests.appID, processingTimeout: timeout)
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

        /// Runs `body` with the HTTP mock and the log mock registered, and the real process runner, which reads the IPA.
        static func withRegistrations<T>(
            _ http: HTTPClientMock, _ log: LogMock, _ body: () async throws -> T
        ) async throws -> T {
            let restore = secretsSetUp()
            defer { restore() }
            registerDependencies()
            register(HTTPClient.self, http)
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

        /// A successful upload reads the app, lists the uploads of the build, sends two parts, commits and reads the
        /// upload until it is processing. It sends each part with exactly its own headers, the right bytes, and no
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
            #expect(requests.map { "\($0.method) \($0.url.path)" } == [
                "GET /v1/apps/\(Self.appID)",
                "GET /v1/apps/\(Self.appID)/buildUploads",
                "POST /v1/buildUploads",
                "POST /v1/buildUploadFiles",
                "PUT /part-1",
                "PUT /part-2",
                "PATCH /v1/buildUploadFiles/\(Self.fileID)",
                "GET /v1/buildUploads/\(Self.uploadID)",
                "GET /v1/buildUploadFiles/\(Self.fileID)",
                "GET /v1/buildUploads/\(Self.uploadID)",
                "GET /v1/buildUploadFiles/\(Self.fileID)",
            ])

            let half = data.count / 2
            let puts = requests.filter { $0.method == "PUT" }
            #expect(puts.count == 2)
            #expect(puts[0].url == Self.partOneURL)
            #expect(puts[0].headers == ["x-test-part": "1"])
            #expect(puts[0].body == data.subdata(in: 0..<half))
            #expect(puts[1].url == Self.partTwoURL)
            #expect(puts[1].headers == ["x-test-part": "2", "x-test-extra": "yes"])
            #expect(puts[1].body == data.subdata(in: half..<data.count))
            #expect(puts.allSatisfy { $0.headers["Authorization"] == nil && $0.secretHeaders["Authorization"] == nil })

            let create = try JSONDecoder().decode(RequestBody.self, from: try #require(requests[2].body))
            #expect(create.data.type == "buildUploads")
            #expect(create.data.attributes?.cfBundleShortVersionString == "1.2.3")
            #expect(create.data.attributes?.cfBundleVersion == "42")
            #expect(create.data.attributes?.platform == "IOS")
            #expect(create.data.relationships?.app?.data.id == Self.appID)

            let reserve = try JSONDecoder().decode(RequestBody.self, from: try #require(requests[3].body))
            #expect(reserve.data.attributes?.assetType == "ASSET")
            #expect(reserve.data.attributes?.fileName == "MyApp.ipa")
            #expect(reserve.data.attributes?.fileSize == data.count)
            #expect(reserve.data.attributes?.uti == "com.apple.ipa")
            #expect(reserve.data.relationships?.buildUpload?.data.id == Self.uploadID)

            let commit = try JSONDecoder().decode(RequestBody.self, from: try #require(requests[6].body))
            #expect(commit.data.type == "buildUploadFiles")
            #expect(commit.data.attributes?.uploaded == true)
            #expect(commit.data.attributes?.sourceFileChecksums?.file.algorithm == "MD5")
            #expect(commit.data.attributes?.sourceFileChecksums?.file.hash == Self.md5Hex(data))

            let token = try Self.token(harness.http)
            let lines = harness.log.loggedLines.joined(separator: "\n")
            let tenths = half * 10 / data.count
            #expect(lines.contains("Uploaded \(tenths * 10)% ("))
            #expect(lines.contains("Uploaded 100% ("))
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

        /// A part that gets 503 twice is sent again after 2 and 4 seconds, and the third attempt succeeds.
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
        }

        /// A part that gets 403 fails at once with its number and status. Nothing is retried, the file is not committed,
        /// and neither the token nor the pre-signed URL is in the error or the log.
        @Test func partRefusedWithForbiddenFailsAtOnceWithoutTheURL() async throws {
            let harness = Harness()
            let data = try Self.fixtureData()
            try Self.queueLookup(harness.http)
            try Self.queueList(harness.http)
            try Self.queueUpload(harness.http, size: data.count, partStatuses: [[403]])

            let error = await harness.failure()

            let message = try #require(error?.message)
            #expect(message.hasPrefix("Uploading part 1 of the IPA failed with status 403."))
            #expect(!message.contains("PART-ONE-SIGNATURE"))
            #expect(!message.contains("upload.example.com"))
            #expect(harness.sleeps.durations.isEmpty)
            #expect(harness.http.requests.filter { $0.method == "PUT" }.count == 1)
            #expect(!harness.http.requests.contains { $0.method == "PATCH" })
            let token = try Self.token(harness.http)
            #expect(!message.contains(token))
            #expect(!harness.log.loggedLines.joined().contains(token))
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
