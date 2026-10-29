import Foundation
import SwiftCI
#if canImport(Security)
import Security
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// Distribution methods supported by the builtin `Fastlane.matchUpdateBuiltin`.
public enum MatchType: String {
    case appstore, adhoc, enterprise
}

/// Swift helpers for invoking fastlane and the native `match` implementation.
public struct Fastlane {
    /// Run `fastlane match` (Ruby) in readonly mode to install signing assets.
    /// - Parameters:
    ///   - type: Distribution type (appstore/adhoc/enterprise).
    ///   - appIdentifier: Bundle identifier to use for profile selection.
    ///   - teamId: Apple Developer Team ID.
    ///
    /// Opens a step named "Install signing assets with fastlane match (appstore, com.example.myapp)" when called
    /// at the top level of a command. `step` renames it.
    public static func match(type: MatchType, appIdentifier: String, teamId: String, step name: String? = nil) async throws {
        try await step(default: "Install signing assets with fastlane match (\(type.rawValue), \(appIdentifier))", name: name) {
            try await Tool(
                command: "fastlane",
                arguments: ["match", type.rawValue, "--readonly", "--app_identifier", appIdentifier, "--team_id", teamId]
            ).run()
        }
    }

    /// Run `fastlane match` (Ruby) with `--force` to refresh profiles if needed.
    /// - Parameters:
    ///   - type: Distribution type (appstore/adhoc/enterprise).
    ///   - appIdentifier: Bundle identifier.
    ///   - teamId: Apple Developer Team ID.
    ///
    /// Opens a step named "Update signing assets with fastlane match (appstore, com.example.myapp)" when called
    /// at the top level of a command. `step` renames it.
    public static func matchUpdate(type: MatchType, appIdentifier: String, teamId: String, step name: String? = nil) async throws {
        try await step(default: "Update signing assets with fastlane match (\(type.rawValue), \(appIdentifier))", name: name) {
            try await Tool(
                command: "fastlane",
                arguments: ["match", type.rawValue, "--force", "--app_identifier", appIdentifier, "--team_id", teamId]
            ).run()
        }
    }
    
    /// Native Swift implementation of the "readonly install" portion of fastlane match.
    ///
    /// This clones the match repo, decrypts signing assets (V1/V2), imports certificates into
    /// the specified keychain, installs the provisioning profile, and exports sigh_* env vars.
    ///
    /// Expected environment variables:
    /// - MATCH_GIT_URL (required)
    /// - MATCH_PASSWORD (required)
    /// - MATCH_GIT_BRANCH (default: "master")
    /// - MATCH_PLATFORM (default: "ios")
    /// - MATCH_KEYCHAIN_NAME (default: "login.keychain-db")
    /// - MATCH_KEYCHAIN_PASSWORD (optional)
    /// - MATCH_CERTIFICATE_ID (optional)
    ///
    /// Opens a step named "Install signing assets (appstore, com.example.myapp)" when called at the top level
    /// of a command. `step` renames it.
    public func matchUpdateBuiltin(type: MatchType, appIdentifier: String, teamId: String, step name: String? = nil) async throws {
        try await step(default: "Install signing assets (\(type.rawValue), \(appIdentifier))", name: name) {
            @Use var log: Log

            // Configuration via environment (kept minimal but compatible with fastlane match)
            let gitURL = try Environment.required("MATCH_GIT_URL")
            // Checked here. The value is revealed only for the decryption below.
            let password = Secret("MATCH_PASSWORD")
            _ = try password.revealedValue()
            let branch = Environment.optional("MATCH_GIT_BRANCH") ?? "master"
            let platform = Environment.optional("MATCH_PLATFORM") ?? "ios"
            let keychainName = Environment.optional("MATCH_KEYCHAIN_NAME") ?? "login.keychain-db"
            // Optional, used for the partition list. The tool is built and checked now, before anything is cloned or
            // imported. An invalid password (for example one with a line feed) stops the install here.
            let keychainURL = resolveKeychainURL(from: keychainName)
            let partitionTool = try Secret.optional("MATCH_KEYCHAIN_PASSWORD").map {
                try partitionListTool(keychainURL: keychainURL, password: $0)
            }
            let wantedCertId = Environment.optional("MATCH_CERTIFICATE_ID")
            let git = try GitCredentialHelper.resolve(
                url: gitURL,
                basicAuthorization: Secret.optional(GitCredentialHelper.basicVariable),
                bearerAuthorization: Secret.optional(GitCredentialHelper.bearerVariable),
                inheritedEnvironment: ProcessInfo.processInfo.environment
            )

            // 1) Clone certificates repo to a temp folder
            let tmp = try TemporaryDirectory(name: "match-$UUID")
            let tempDir = tmp.childURL(name: branch)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let cloneArgs = [
                "clone", git.url, tempDir.filePath,
            ]
            try await Tool(command: "/usr/bin/git", arguments: cloneArgs, environment: git.environment).run()
            // Checkout branch. A failure is logged as a warning, and the install continues with the default branch.
            try await runTolerated(
                Tool(command: "/usr/bin/git", arguments: ["-C", tempDir.filePath, "checkout", branch], environment: git.environment),
                what: "checking out branch '\(branch)'"
            )

            // 2) Decrypt all encrypted files in place (cer, p12, mobileprovision, provisionprofile)
            try await decryptMatchRepository(at: tempDir, password: try password.revealedValue())

            // 3) Resolve paths for certs and profiles
            let certType = mapCertType(from: type)
            let provType = mapProvType(from: type)

            let certsDir = tempDir.appending(path: "certs").appending(path: certType)
            let profilesDir = tempDir.appending(path: "profiles").appending(path: provType)

            // 3a) Pick certificate (.cer) and its matching .p12
            let cerCandidates = try listFiles(directory: certsDir, extensions: ["cer"]).sorted { $0.filePath < $1.filePath }
            guard let cerURL = try selectCertURL(candidates: cerCandidates, wantedId: wantedCertId) else {
                throw BuildError(message: "No certificate found for type '\(certType)'.")
            }
            let p12URL = URL(fileURLWithPath: cerURL.filePath.replacingOccurrences(of: ".cer", with: ".p12"))
            if !FileManager.default.fileExists(atPath: p12URL.filePath) {
                throw BuildError(message: "Missing private key (.p12) for certificate '\(cerURL.lastPathComponent)'.")
            }

            // 3b) Find provisioning profile for bundle id and platform
            let profileBaseName = profileFileBaseName(provType: provType, appIdentifier: appIdentifier, platform: platform)
            let profileExt = ["macos", "catalyst"].contains(platform) ? "provisionprofile" : "mobileprovision"
            let profileCandidates = try listFiles(directory: profilesDir, names: [profileBaseName], extensions: [profileExt])
            guard let profileURL = profileCandidates.sorted(by: { $0.filePath < $1.filePath }).last else {
                throw BuildError(message: "No provisioning profile found named '\(profileBaseName).\(profileExt)'.")
            }

            // 4) Import cert + key to keychain (idempotent)
            log("Installing certificate into keychain: \(keychainURL.filePath)")
            try await importIntoKeychain(itemURL: cerURL, keychainURL: keychainURL, itemPassword: "", partitionList: partitionTool)
            try await importIntoKeychain(itemURL: p12URL, keychainURL: keychainURL, itemPassword: "", partitionList: partitionTool)

            // 5) Install provisioning profile to Xcode directory
            let profileInfo = try await decodeProvisioningProfile(url: profileURL)
            let uuid = profileInfo.uuid
            let installedProfileURL = try installProvisioningProfile(src: profileURL, uuid: uuid, isMac: profileInfo.isMac)
            log.success("Installed provisioning profile: \(installedProfileURL.filePath)")

            // 6) Export useful environment variables (mimic fastlane match Utils.fill_environment)
            if let teamIdentifier = profileInfo.teamIdentifier {
                setenv(envVarName(appIdentifier: appIdentifier, provType: provType, platform: platform, suffix: "team-id"), teamIdentifier, 1)
            }
            if let certificateCommonName = profileInfo.certificateCommonName {
                setenv(envVarName(appIdentifier: appIdentifier, provType: provType, platform: platform, suffix: "certificate-name"), certificateCommonName, 1)
            }
            if let profileName = profileInfo.name {
                setenv(envVarName(appIdentifier: appIdentifier, provType: provType, platform: platform, suffix: "profile-name"), profileName, 1)
            }
            setenv(envVarName(appIdentifier: appIdentifier, provType: provType, platform: platform, suffix: nil), uuid, 1)
            setenv(envVarName(appIdentifier: appIdentifier, provType: provType, platform: platform, suffix: "profile-path"), installedProfileURL.filePath, 1)

            log.success("fastlane match (builtin) completed for \(appIdentifier) [\(type.rawValue)]")
        }
    }
}

// MARK: - Helpers (Fastlane builtin)

private extension Fastlane {
    /// Map a `MatchType` to the certificates subfolder used by match.
    func mapCertType(from type: MatchType) -> String {
        switch type {
        case .appstore, .adhoc: return "distribution"
        case .enterprise: return "enterprise"
        }
    }

    /// Map a `MatchType` to the profiles subfolder used by match.
    func mapProvType(from type: MatchType) -> String {
        switch type {
        case .appstore: return "appstore"
        case .adhoc: return "adhoc"
        case .enterprise: return "enterprise"
        }
    }

    /// Build expected profile base name used by match for stored files.
    /// Appends platform for tvOS or Catalyst.
    func profileFileBaseName(provType: String, appIdentifier: String, platform: String) -> String {
        let profileTypeName: String
        switch provType {
        case "appstore": profileTypeName = "AppStore"
        case "adhoc": profileTypeName = "AdHoc"
        case "enterprise": profileTypeName = "InHouse"
        default: profileTypeName = provType.capitalized
        }
        if platform == "tvos" || platform == "catalyst" {
            return "\(profileTypeName)_\(appIdentifier)_\(platform)"
        } else {
            return "\(profileTypeName)_\(appIdentifier)"
        }
    }

    /// List files in directory filtered by base names and extensions (case-insensitive extensions).
    func listFiles(directory: URL, names: [String]? = nil, extensions: [String]) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.filePath) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return urls.filter { url in
            let name = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension.lowercased()
            return extensions.contains(ext) && (names == nil || names!.contains(name))
        }
    }

    /// Select a certificate URL from candidates, honoring MATCH_CERTIFICATE_ID if provided.
    func selectCertURL(candidates: [URL], wantedId: String?) throws -> URL? {
        guard !candidates.isEmpty else { return nil }
        if let id = wantedId {
            return candidates.first { $0.lastPathComponent.contains(id) }
        }
        return candidates.last
    }

    /// Resolve a keychain logical name into an absolute file URL.
    func resolveKeychainURL(from keychainName: String) -> URL {
        if keychainName.contains("/") { return URL(fileURLWithPath: keychainName) }
        // Normalize typical names: login.keychain, login.keychain-db, or custom
        let libKeychains = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Keychains")
        if keychainName.hasSuffix(".keychain") || keychainName.hasSuffix(".keychain-db") {
            return libKeychains.appending(path: keychainName)
        } else {
            return libKeychains.appending(path: "\(keychainName).keychain-db")
        }
    }

    /// Import a certificate/key file into a keychain and optionally set partition list.
    /// `partitionList` is built before the install starts, so that an invalid keychain password is found first. It is
    /// `nil` when no keychain password is given.
    func importIntoKeychain(itemURL: URL, keychainURL: URL, itemPassword: String, partitionList: Tool?) async throws {
        try await runImport(item: itemURL, keychainURL: keychainURL, itemPassword: itemPassword)

        // Set the partition list if a keychain password is given. A failure is logged as a warning.
        if let partitionList {
            try await runTolerated(partitionList, what: "setting the key partition list")
        }
    }

    /// Install a provisioning profile into the user profiles directory named by UUID.
    func installProvisioningProfile(src: URL, uuid: String, isMac: Bool) throws -> URL {
        let profilesDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/MobileDevice/Provisioning Profiles")
        try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        let ext = isMac ? ".provisionprofile" : ".mobileprovision"
        let dst = profilesDir.appending(path: "\(uuid)\(ext)")
        if src.filePath != dst.filePath {
            // Copy
            if FileManager.default.fileExists(atPath: dst.filePath) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.copyItem(at: src, to: dst)
        }
        return dst
    }

    /// Build a sigh_* environment variable name compatible with fastlane match.
    func envVarName(appIdentifier: String, provType: String, platform: String, suffix: String?) -> String {
        var parts = ["sigh", appIdentifier, provType]
        if platform != "ios" { parts.append(platform) }
        if let s = suffix { parts.append(s) }
        return parts.joined(separator: "_")
    }
}

// MARK: - Provisioning Profile decode

/// Parsed fields from a provisioning profile used by install/config steps.
private struct ProfileInfo {
    let uuid: String
    let name: String?
    let isMac: Bool
    let teamIdentifier: String?
    let certificateCommonName: String?
}

private extension Fastlane {
    /// Decode a provisioning profile as plist and extract fields used for installation.
    func decodeProvisioningProfile(url: URL) async throws -> ProfileInfo {
        // security cms -D -i <path>
        let xml = try await Tool(command: "/usr/bin/security", arguments: ["cms", "-D", "-i", url.filePath]).output()
        guard let data = xml.data(using: .utf8) else { throw BuildError(message: "Failed to decode provisioning profile plist.") }
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = plist as? [String: Any] else { throw BuildError(message: "Provisioning profile plist not a dictionary.") }
        guard let uuid = dict["UUID"] as? String else { throw BuildError(message: "Provisioning profile missing UUID.") }
        let name = dict["Name"] as? String
        let teamId = (dict["TeamIdentifier"] as? [String])?.first
        let platformArr = dict["Platform"] as? [String] ?? []
        let isMac = platformArr.contains("OSX")

        // Extract certificate common name from DeveloperCertificates[0]
        var commonName: String? = nil
        if let devCerts = dict["DeveloperCertificates"] as? [Any], let first = devCerts.first as? Data {
            commonName = extractCommonName(fromCertificateData: first)
        }
        return ProfileInfo(uuid: uuid, name: name, isMac: isMac, teamIdentifier: teamId, certificateCommonName: commonName)
    }

    /// Extract certificate common name from DER-encoded certificate bytes.
    func extractCommonName(fromCertificateData data: Data) -> String? {
        #if canImport(Security)
        if let cert = SecCertificateCreateWithData(nil, data as CFData) {
            if let summary = SecCertificateCopySubjectSummary(cert) as String? {
                return summary
            }
        }
        #endif
        return nil
    }
}

// MARK: - Decryption

private extension Fastlane {
    /// Walk the match repo and decrypt any supported file types in place.
    func decryptMatchRepository(at dir: URL, password: String) async throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: dir.filePath) else { return }
        while let elem = enumerator.nextObject() as? String {
            let url = dir.appending(path: elem)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.filePath, isDirectory: &isDir), isDir.boolValue { continue }
            if ["cer", "p12", "mobileprovision", "provisionprofile"].contains(url.pathExtension.lowercased()) {
                try decryptFileInPlace(url: url, password: password)
            }
        }
    }

    /// Decrypt a single file in place if it uses match V1/V2 formats; ignore if already plaintext.
    func decryptFileInPlace(url: URL, password: String) throws {
        // Files are base64 text with prefixes: "match_encrypted_v2__" or "Salted__"
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let raw = Data(base64Encoded: text) else { return } // already decrypted
        let v2Prefix = "match_encrypted_v2__".data(using: .utf8)!
        let v1Prefix = "Salted__".data(using: .utf8)!

        let decrypted: Data
        if raw.starts(with: v2Prefix) {
            // [20:v2][8:salt][16:auth_tag][rest:cipher]
            let salt = raw.subdata(in: 20..<(20+8))
            let auth = raw.subdata(in: 28..<(28+16))
            let cipher = raw.subdata(in: 44..<raw.count)
            decrypted = try decryptV2(ciphertext: cipher, salt: salt, authTag: auth, password: password)
        } else if raw.starts(with: v1Prefix) {
            // [8:Salted__][8:salt][rest:cipher]
            let salt = raw.subdata(in: 8..<(8+8))
            let cipher = raw.subdata(in: 16..<raw.count)
            // Try MD5 then fallback to SHA256 like Ruby implementation
            if let data = try? decryptV1(ciphertext: cipher, salt: salt, password: password, hash: .md5) {
                decrypted = data
            } else {
                decrypted = try decryptV1(ciphertext: cipher, salt: salt, password: password, hash: .sha256)
            }
        } else {
            // Not encrypted (already plain DER/CMS) – nothing to do
            return
        }
        try decrypted.write(to: url)
    }
}


/// Hash algorithms supported for OpenSSL-compatible derivation.
private enum HashAlgo { case md5, sha256 }

private extension Fastlane {
    /// Decrypt OpenSSL V1 (AES-256-CBC + EVP_BytesToKey) encrypted payload.
    func decryptV1(ciphertext: Data, salt: Data, password: String, hash: HashAlgo) throws -> Data {
        // Derive key (32) and iv (16)
        let keyIv = evpBytesToKey(password: password.data(using: .utf8)!, salt: salt, keyLength: 32, ivLength: 16, hash: hash)
        let key = keyIv.subdata(in: 0..<32)
        let iv = keyIv.subdata(in: 32..<48)
        return try aes256cbcDecrypt(data: ciphertext, key: key, iv: iv)
    }

    /// Decrypt V2 (AES-256-GCM) payload derived via PBKDF2-HMAC-SHA256 (10k iters).
    func decryptV2(ciphertext: Data, salt: Data, authTag: Data, password: String) throws -> Data {
        let derivedLen = 32 + 12 + 24
        let derived = try pbkdf2sha256(password: password.data(using: .utf8)!, salt: salt, rounds: 10_000, length: derivedLen)
        let key = derived.subdata(in: 0..<32)
        let iv = derived.subdata(in: 32..<(32+12))
        let authData = derived.subdata(in: (32+12)..<derived.count)
        #if canImport(CryptoKit)
        let sealedBox = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: authTag)
        let opened = try AES.GCM.open(sealedBox, using: SymmetricKey(data: key), authenticating: authData)
        return opened
        #else
        throw BuildError(message: "AES.GCM not available on this platform")
        #endif
    }

    /// PBKDF2 (HMAC-SHA256) derivation helper.
    func pbkdf2sha256(password: Data, salt: Data, rounds: Int, length: Int) throws -> Data {
        #if canImport(CommonCrypto)
        var out = Data(count: length)
        let result = out.withUnsafeMutableBytes { outPtr in
            salt.withUnsafeBytes { saltPtr in
                password.withUnsafeBytes { pwdPtr in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         pwdPtr.bindMemory(to: Int8.self).baseAddress, password.count,
                                         saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                         UInt32(rounds),
                                         outPtr.bindMemory(to: UInt8.self).baseAddress, length)
                }
            }
        }
        guard result == kCCSuccess else { throw BuildError(message: "PBKDF2 failed: \(result)") }
        return out
        #else
        throw BuildError(message: "CommonCrypto not available for PBKDF2")
        #endif
    }

    /// OpenSSL EVP_BytesToKey-compatible derivation producing key||iv.
    func evpBytesToKey(password: Data, salt: Data, keyLength: Int, ivLength: Int, hash: HashAlgo) -> Data {
        var d = Data()
        var di = Data()
        while d.count < keyLength + ivLength {
            var ctx = Data()
            ctx.append(di)
            ctx.append(password)
            ctx.append(salt)
            di = digest(data: ctx, hash: hash)
            d.append(di)
        }
        return d.subdata(in: 0..<(keyLength + ivLength))
    }

    /// Compute MD5/SHA256 digest using CryptoKit or CommonCrypto fallback.
    func digest(data: Data, hash: HashAlgo) -> Data {
        #if canImport(CryptoKit)
        switch hash {
        case .md5:
            let d = Insecure.MD5.hash(data: data)
            return Data(d)
        case .sha256:
            let d = SHA256.hash(data: data)
            return Data(d)
        }
        #else
        // Fallback using CommonCrypto
        switch hash {
        case .md5:
            var out = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
            data.withUnsafeBytes { ptr in _ = CC_MD5(ptr.baseAddress, CC_LONG(data.count), &out) }
            return Data(out)
        case .sha256:
            var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            data.withUnsafeBytes { ptr in _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &out) }
            return Data(out)
        }
        #endif
    }

    /// AES-256-CBC decrypt with PKCS#7 padding using CommonCrypto.
    func aes256cbcDecrypt(data: Data, key: Data, iv: Data) throws -> Data {
        #if canImport(CommonCrypto)
        var outLength: size_t = 0
        var outData = Data(count: data.count + kCCBlockSizeAES128)
        let outCapacity = outData.count
        let status: CCCryptorStatus = outData.withUnsafeMutableBytes { outPtr in
            guard let outBase = outPtr.baseAddress else { return CCCryptorStatus(kCCMemoryFailure) }
            return data.withUnsafeBytes { dataPtr in
                let dataBase = dataPtr.baseAddress
                return key.withUnsafeBytes { keyPtr in
                    let keyBase = keyPtr.baseAddress
                    return iv.withUnsafeBytes { ivPtr in
                        let ivBase = ivPtr.baseAddress
                        return CCCrypt(CCOperation(kCCDecrypt),
                                       CCAlgorithm(kCCAlgorithmAES128),
                                       CCOptions(kCCOptionPKCS7Padding),
                                       keyBase, key.count,
                                       ivBase,
                                       dataBase, data.count,
                                       outBase, outCapacity,
                                       &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw BuildError(message: "AES-CBC decryption failed: \(status)") }
        outData.removeSubrange(outLength..<outData.count)
        return outData
        #else
        throw BuildError(message: "CommonCrypto not available for AES-CBC")
        #endif
    }
}

extension Fastlane {
    /// The message `security import` prints when the item is already in the keychain. Re-running an install is
    /// expected, so this is success. The line is hidden on the console, and it stays in the full log.
    static let duplicateItemMessage = "The specified item already exists in the keychain."

    /// Imports `item` into the keychain. Exit code 1 with the duplicate-item message is success, without a warning.
    /// Any other non-zero exit code is logged as a warning, and a program that cannot be started still throws.
    func runImport(item: URL, keychainURL: URL, itemPassword: String) async throws {
        @Use var log: Log

        let args = ["import", item.filePath, "-k", keychainURL.filePath, "-P", itemPassword,
                    "-T", "/usr/bin/codesign", "-T", "/usr/bin/security", "-T", "/usr/bin/productbuild", "-T", "/usr/bin/productsign"]
        let tool = Tool(command: "/usr/bin/security", arguments: args, filters: [filter(Self.duplicateItemMessage)])
        let result = try await tool.result()
        guard result.exitCode != 0 else { return }

        let isDuplicate = result.exitCode == 1
            && result.stderr.components(separatedBy: "\n").contains { $0.hasSuffix(Self.duplicateItemMessage) }
        if !isDuplicate {
            let name = item.lastPathComponent
            log.warning("\(tool.displayName) exited with code \(result.exitCode) while importing '\(name)'. The install continues.")
        }
    }

    /// Runs a tool whose failure the install tolerates. A non-zero exit code is logged as a warning that names the tool
    /// and the code, and the caller continues. Other failures, such as a program that cannot be started, still throw.
    func runTolerated(_ tool: Tool, what: String) async throws {
        @Use var log: Log

        let result = try await tool.result()
        if result.exitCode != 0 {
            log.warning("\(tool.displayName) exited with code \(result.exitCode) while \(what). The install continues.")
        }
    }
}

extension Fastlane {
    /// The `set-key-partition-list` call of the native install, as a `security -i` tool. The password is revealed here
    /// and sent on standard input only. Tests build the tool and check it without running it.
    func partitionListTool(keychainURL: URL, password: Secret) throws -> Tool {
        try SecurityInteractive.tool(for: [
            SecurityArgument(kind: "command", value: "set-key-partition-list"),
            SecurityArgument(kind: "option", value: "-S"),
            SecurityArgument(kind: "option", value: "apple-tool:,apple:,codesign:"),
            SecurityArgument(kind: "option", value: "-s"),
            SecurityArgument(kind: "option", value: "-k"),
            SecurityArgument(kind: "keychain password", value: try password.revealedValue()),
            SecurityArgument(kind: "keychain path", value: keychainURL.filePath),
        ])
    }
}
