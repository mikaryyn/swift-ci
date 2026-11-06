#if os(macOS)
import Foundation
import SwiftCI

/// How often the build upload is read after the commit.
private let pollInterval = Duration.seconds(10)

extension AppStoreConnect {
    /// Uploads an iOS IPA as a new build of an app with the Build Upload API. The version and the build number are read
    /// from the IPA.
    ///
    /// The step ends when App Store Connect has accepted the uploaded file, as `altool` ends its upload. Processing of the
    /// build continues in App Store Connect after the step. Before any byte is sent, the step checks that the app has the
    /// bundle identifier of the IPA, and that the app has no build upload of the same version and build number that has
    /// not failed.
    ///
    /// Opens a step named "Upload MyApp.ipa to App Store Connect" when called at the top level of a command. `step` renames it.
    ///
    /// - Parameters:
    ///   - ipa: The IPA file, an export of an iOS app.
    ///   - appID: The ID of the app in App Store Connect, such as `1234567890`.
    ///   - processingTimeout: How long the step waits for App Store Connect to accept the file after the commit. The step
    ///     fails when this passes first.
    ///   - name: The name of the step, if it is not the default.
    /// - Returns: The build upload, in the state that App Store Connect reported when it accepted the file.
    @discardableResult
    public func uploadBuild(
        ipa: URL, appID: String, processingTimeout: Duration = .seconds(30 * 60), step name: String? = nil
    ) async throws -> BuildUpload {
        try await step(default: "Upload \(ipa.lastPathComponent) to App Store Connect", name: name) {
            try await uploadIPA(ipa, appID: appID, processingTimeout: processingTimeout)
        }
    }

    private func uploadIPA(_ ipa: URL, appID: String, processingTimeout: Duration) async throws -> BuildUpload {
        @Use var log: Log
        let info = try await IPAInfo.read(ipa)
        let fileSize = try Self.fileSize(of: ipa)
        log("Uploading \(ipa.lastPathComponent) (\(BuildUploadParts.size(fileSize))) as \(info.bundleIdentifier) \(info.shortVersion) (\(info.buildVersion)) to app \(appID).")

        try await verifyApp(appID, bundleIdentifier: info.bundleIdentifier)
        try await verifyNoUploadOfSameBuild(appID, info)
        let uploadID = try await createBuildUpload(appID, info)
        let file = try await reserveFile(ipa, fileSize: fileSize, uploadID: uploadID)
        let operations = file.operations.sorted { $0.partNumber < $1.partNumber }
        let headerNames = (operations.first?.requestHeaders ?? []).map(\.name)
        log("Created build upload \(uploadID) and file \(file.id). App Store Connect returned \(operations.count) upload operations; the first sends the headers: \(headerNames.isEmpty ? "none" : headerNames.joined(separator: ", ")).")

        let parts = BuildUploadParts(ipa: ipa, fileSize: fileSize, now: now, sleep: sleep)
        let md5 = try await parts.send(operations)
        try await commit(fileID: file.id, md5: md5)
        let state = try await waitForAcceptance(uploadID: uploadID, fileID: file.id, info: info, timeout: processingTimeout)

        log.success("Uploaded \(info.bundleIdentifier) \(info.shortVersion) (\(info.buildVersion)) to App Store Connect. Processing continues in App Store Connect.")
        return BuildUpload(
            id: uploadID,
            appID: appID,
            bundleIdentifier: info.bundleIdentifier,
            version: info.shortVersion,
            build: info.buildVersion,
            state: state
        )
    }

    /// Throws a ``BuildError`` when the app does not have the bundle identifier of the IPA, or when the API key cannot see
    /// the app. Reads the app with `GET /v1/apps/{id}`.
    private func verifyApp(_ appID: String, bundleIdentifier: String) async throws {
        let path = "/v1/apps/\(appID)"
        let response = try await send(
            "GET", path, query: [URLQueryItem(name: "fields[apps]", value: "bundleId")], accepting: 404
        )
        guard response.statusCode != 404 else {
            throw BuildError(message: "No app with ID \(appID) is visible to this API key. Check the app ID, and that the API key has access to the app in App Store Connect.")
        }
        let app = try decode(ResponseDocument<AppAttributes>.self, from: response, "GET", path).data
        guard app.attributes.bundleId == bundleIdentifier else {
            throw BuildError(message: "App \(appID) has the bundle identifier \(app.attributes.bundleId), but the IPA is for \(bundleIdentifier). The IPA belongs to another app record. Check the app ID.")
        }
    }

    /// Throws a ``BuildError`` when the app already has a build upload of the same version and build number that has not
    /// failed. Such a build upload blocks the number, so the build number must be increased.
    private func verifyNoUploadOfSameBuild(_ appID: String, _ info: IPAInfo) async throws {
        let uploads: [ResponseResource<BuildUploadAttributes>] = try await getAll(
            "/v1/apps/\(appID)/buildUploads",
            query: [
                URLQueryItem(name: "filter[cfBundleShortVersionString]", value: info.shortVersion),
                URLQueryItem(name: "filter[cfBundleVersion]", value: info.buildVersion),
            ]
        )
        // The version and build are compared here too, so that a filter that the server ignored cannot block every build.
        let existing = uploads.first { upload in
            let attributes = upload.attributes
            return (attributes.cfBundleShortVersionString ?? info.shortVersion) == info.shortVersion
                && (attributes.cfBundleVersion ?? info.buildVersion) == info.buildVersion
                && (attributes.state?.state ?? "") != "FAILED"
        }
        if let existing {
            throw BuildError(message: "Version \(info.shortVersion) build \(info.buildVersion) was already uploaded to app \(appID) (build upload \(existing.id) is \(existing.attributes.state?.state ?? "in an unknown state")). Increase the build number, archive and export the IPA again, then run the step again.")
        }
    }

    /// Creates the build upload and returns its ID. A 409 means that App Store Connect refused the version and build, which
    /// is most often a duplicate, so the error says so and shows Apple's details.
    private func createBuildUpload(_ appID: String, _ info: IPAInfo) async throws -> String {
        let path = "/v1/buildUploads"
        let resource = BuildUploadCreate(
            attributes: .init(
                cfBundleShortVersionString: info.shortVersion,
                cfBundleVersion: info.buildVersion,
                platform: info.platform
            ),
            relationships: .init(app: ToOneRelationship(data: ResourceIdentifier(type: "apps", id: appID)))
        )
        let body = try Self.encode(RequestDocument(data: resource), "POST", path)
        let response = try await send("POST", path, body: body, accepting: 409)
        guard response.statusCode != 409 else {
            throw BuildError(message: "App Store Connect refused to create the build upload of version \(info.shortVersion) build \(info.buildVersion) for app \(appID), probably because that version and build already exist. Increase the build number, then run the step again.\(Self.appleSays(in: response.body))")
        }
        return try decode(ResponseDocument<BuildUploadAttributes>.self, from: response, "POST", path).data.id
    }

    /// Reserves the file of the build upload. Returns the file's ID and the upload operations that App Store Connect gave.
    private func reserveFile(
        _ ipa: URL, fileSize: Int, uploadID: String
    ) async throws -> (id: String, operations: [UploadOperation]) {
        let resource = BuildUploadFileCreate(
            attributes: .init(
                assetType: "ASSET",
                fileName: ipa.lastPathComponent,
                fileSize: fileSize,
                uti: "com.apple.ipa"
            ),
            relationships: .init(buildUpload: ToOneRelationship(data: ResourceIdentifier(type: "buildUploads", id: uploadID)))
        )
        let document = try await post(
            "/v1/buildUploadFiles", body: RequestDocument(data: resource), as: ResponseDocument<BuildUploadFileAttributes>.self
        ).data
        return (document.id, document.attributes.uploadOperations ?? [])
    }

    /// Commits the uploaded file with its MD5, so that App Store Connect checks the file against it.
    private func commit(fileID: String, md5: String) async throws {
        let path = "/v1/buildUploadFiles/\(fileID)"
        let resource = BuildUploadFileCommit(
            id: fileID,
            attributes: .init(
                uploaded: true,
                sourceFileChecksums: .init(file: .init(algorithm: "MD5", hash: md5))
            )
        )
        _ = try await send("PATCH", path, body: try Self.encode(RequestDocument(data: resource), "PATCH", path))
    }

    /// Reads the build upload and its file every ``pollInterval`` until App Store Connect has accepted the file, which is
    /// the state `PROCESSING` or `COMPLETE`. Throws a ``BuildError`` when either state is `FAILED`, or when the timeout
    /// passes first. A state change is logged once, and unknown states are kept polling.
    private func waitForAcceptance(
        uploadID: String, fileID: String, info: IPAInfo, timeout: Duration
    ) async throws -> BuildUploadState {
        @Use var log: Log
        let deadline = now().addingTimeInterval(timeout.timeInterval)
        var lastStates: String?
        while true {
            let upload = try await get("/v1/buildUploads/\(uploadID)", as: ResponseDocument<BuildUploadAttributes>.self).data.attributes
            let file = try await get("/v1/buildUploadFiles/\(fileID)", as: ResponseDocument<BuildUploadFileAttributes>.self).data.attributes
            let buildState = upload.state?.state ?? "UNKNOWN"
            let fileState = file.assetDeliveryState?.state ?? "UNKNOWN"
            let states = "build upload \(buildState), file \(fileState)"
            if states != lastStates {
                log("App Store Connect: \(states)")
                lastStates = states
            }

            let state = BuildUploadState(apiValue: buildState)
            if state == .failed || fileState == "FAILED" {
                reportNotices(upload, file)
                throw Self.processingFailure(info, upload, file)
            }
            if state == .processing || state == .complete {
                reportNotices(upload, file)
                return state
            }
            guard now() < deadline else {
                throw BuildError(message: "App Store Connect did not accept the uploaded file within \(Int(timeout.components.seconds)) seconds. The last states were \(states). Check build upload \(uploadID) in App Store Connect before running the step again: a build upload that has not failed blocks the build number.")
            }
            try await self.sleep(pollInterval)
        }
    }

    /// The error of a build upload that App Store Connect failed. It lists every error of the build upload and of the file.
    /// A build number that failed with code 90189 is named as one to increase.
    private static func processingFailure(
        _ info: IPAInfo, _ upload: BuildUploadAttributes, _ file: BuildUploadFileAttributes
    ) -> BuildError {
        let errors = upload.state?.errors ?? []
        let fileErrors = file.assetDeliveryState?.errors ?? []
        var message = "App Store Connect failed the build upload of \(info.bundleIdentifier) \(info.shortVersion) (\(info.buildVersion))."
        if errors.isEmpty && fileErrors.isEmpty {
            message += " App Store Connect gave no error details."
        }
        if !errors.isEmpty {
            message += " Errors: \(describe(errors))."
        }
        if !fileErrors.isEmpty {
            message += " File errors: \(describe(fileErrors))."
        }
        if (errors + fileErrors).contains(where: { $0.code == "90189" }) {
            message += " Increase the build number, archive and export the IPA again, then run the step again."
        }
        return BuildError(message: message)
    }

    /// Logs the warnings and infos of the build upload and of its file. Warnings are also added to the run report.
    private func reportNotices(_ upload: BuildUploadAttributes, _ file: BuildUploadFileAttributes) {
        @Use var log: Log
        for warning in (upload.state?.warnings ?? []) + (file.assetDeliveryState?.warnings ?? []) {
            let text = Self.describe([warning])
            log.warning(text)
            Report.warning(text)
        }
        for info in upload.state?.infos ?? [] {
            log(Self.describe([info]))
        }
    }

    /// The issues as `code: description`, joined with `; `.
    private static func describe(_ issues: [DeliveryIssue]) -> String {
        issues.map { "\($0.code ?? "unknown"): \($0.description ?? "no description")" }.joined(separator: "; ")
    }

    /// The size of the file, in bytes.
    private static func fileSize(of ipa: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: ipa.filePath)
        guard let size = attributes[.size] as? Int else {
            throw BuildError(message: "Cannot read the size of the IPA \(ipa.filePath). Check that the file exists and is readable.")
        }
        return size
    }
}

private extension Duration {
    /// The duration in seconds, with the attoseconds as a fraction.
    var timeInterval: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
#endif
