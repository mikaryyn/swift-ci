/*
> Implemented a native Swift “fastlane match” flow in Fastlane.matchUpdateBuiltin.
  
  What it does
  
  - Clone repo: Uses MATCH_GIT_URL (and MATCH_GIT_BRANCH) to clone the match repo to a temp dir.
  - Decrypt files: Implements OpenSSL-compatible decryption for both formats used by match
      - V2: AES-256-GCM with PBKDF2-HMAC-SHA256 (10,000 iters), prefix match_encrypted_v2__.
      - V1: AES-256-CBC with OpenSSL EVP_BytesToKey (MD5, fallback SHA256), prefix Salted__.
  - Install certificate: Picks cert from certs/<distribution|enterprise>\*.cer (+ matching .p12), imports into the specified keychain, and sets the partition list (if a keychain password is
  provided).
  - Install provisioning profile: Picks profiles/<appstore|adhoc|enterprise>/.mobileprovision, decodes with security cms -D, copies to ~/Library/MobileDevice/Provisioning Profiles/.mobileprovision
  (or .provisionprofile on macOS profiles).
  - Export environment vars (to mimic match):
      - sigh__ = UUID
      - sigh___team-id = TeamIdentifier[0]
      - sigh___certificate-name = Common Name of profile’s DeveloperCertificate
      - sigh___profile-name = profile Name
      - sigh___profile-path = installed path
      - Adds platform suffix for tvos/catalyst (iOS stays without for compatibility).
  
  Where the code lives
  
  - Sources/SwiftCI/Tools/Fastlane.swift
      - Filled in Fastlane.matchUpdateBuiltin
      - Added helper functions for:
      - Repo clone, file discovery, keychain import, profile decode/install
      - Decryption routines (V1/V2) with PBKDF2, AES-GCM (CryptoKit), AES-CBC (CommonCrypto)
      - Utility mapping and env var naming
  
  Required environment variables
  
  - MATCH_GIT_URL: Git URL to the match repository.
  - MATCH_PASSWORD: Decryption passphrase (same one used by fastlane match).
  - Optional:
      - MATCH_GIT_BRANCH (default: master)
      - MATCH_PLATFORM (ios|tvos|catalyst; default: ios)
      - MATCH_KEYCHAIN_NAME (default: login.keychain-db)
      - MATCH_KEYCHAIN_PASSWORD (used for set-key-partition-list; optional)
      - MATCH_CERTIFICATE_ID (choose a specific cert file by id substring)
  
  Usage notes
  
  - Call Fastlane.matchUpdateBuiltin(type:appIdentifier:teamId:) just like the other match helpers.
  - Behavior mirrors fastlane match’s “readonly install” path. It does not create or renew certs/profiles; it fetches, decrypts, and installs what exists in the repo.
  - Certificate import is idempotent; import errors like “already exists” are tolerated.
  - Profiles are installed using UUID naming so Xcode picks them up reliably.
  
  Type mapping (aligned with fastlane)
  
  - MatchType.appstore → certs/distribution, profiles/appstore
  - MatchType.adhoc → certs/distribution, profiles/adhoc
  - MatchType.enterprise → certs/enterprise, profiles/enterprise
  
  Assumptions and trade-offs
  
  - Storage backend: Git only (most common). S3/GCS/GitLab Secure Files are not implemented.
  - No Spaceship/API usage: This standalone “retrieve and install” flow purposely avoids dev portal calls.
  - Decryption is native Swift; no Ruby/OpenSSL CLI dependencies.
  - Keychain partition list is set only if MATCH_KEYCHAIN_PASSWORD is provided; errors are ignored for resilience.
  
  Want me to add:
  
  - Basic auth/bearer/private key support for git clone (MATCH_GIT_BASIC_AUTHORIZATION, MATCH_GIT_BEARER_AUTHORIZATION, MATCH_GIT_PRIVATE_KEY)?
  - Support for additional certificate types (e.g., mac_installer_distribution) and platform-aware profile picking?
  - A small unit test covering decryption (V1/V2) with sample vectors from fastlane?
*/

import Foundation
import System
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
    public static func match(type: MatchType, appIdentifier: String, teamId: String) async throws {
        let tool = Tool(
            command: "/bin/sh",
            arguments: ["fastlane", "match", type.rawValue, "--readonly", "--app_identifier", appIdentifier, "--team_id", teamId],
            filters: []
        )
        try await tool.run()
    }

    /// Run `fastlane match` (Ruby) with `--force` to refresh profiles if needed.
    /// - Parameters:
    ///   - type: Distribution type (appstore/adhoc/enterprise).
    ///   - appIdentifier: Bundle identifier.
    ///   - teamId: Apple Developer Team ID.
    public static func matchUpdate(type: MatchType, appIdentifier: String, teamId: String) async throws {
        let tool = Tool(
            command: "/bin/sh",
            arguments: ["fastlane", "match", type.rawValue, "--force", "--app_identifier", appIdentifier, "--team_id", teamId],
            filters: []
        )
        try await tool.run()
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
    public func matchUpdateBuiltin(type: MatchType, appIdentifier: String, teamId: String) async throws {
        @Use var log: Log

        // Configuration via environment (kept minimal but compatible with fastlane match)
        let gitURL = try Environment.required("MATCH_GIT_URL")
        let password = try Environment.required("MATCH_PASSWORD")
        let branch = Environment.optional("MATCH_GIT_BRANCH") ?? "master"
        let platform = Environment.optional("MATCH_PLATFORM") ?? "ios"
        let keychainName = Environment.optional("MATCH_KEYCHAIN_NAME") ?? "login.keychain-db"
        let keychainPassword = Environment.optional("MATCH_KEYCHAIN_PASSWORD") // optional, used for partition list
        let wantedCertId = Environment.optional("MATCH_CERTIFICATE_ID")

        // 1) Clone certificates repo to a temp folder
        let tmp = try TemporaryDirectory(name: "match-$UUID")
        let tempDir = tmp.childPath(name: branch)
        try FileManager.default.createDirectory(atPath: tempDir.string, withIntermediateDirectories: true)

        let cloneArgs = [
            "clone", gitURL, tempDir.string,
        ]
        try await Tool(command: "/usr/bin/git", arguments: cloneArgs, allowFailure: false).run()
        // Checkout branch (create if not exists locally)
        try await Tool(command: "/usr/bin/git", arguments: ["-C", tempDir.string, "checkout", branch], allowFailure: true).run()

        // 2) Decrypt all encrypted files in place (cer, p12, mobileprovision, provisionprofile)
        try await decryptMatchRepository(at: tempDir, password: password)

        // 3) Resolve paths for certs and profiles
        let certType = mapCertType(from: type)
        let provType = mapProvType(from: type)

        let certsDir = tempDir.appending("certs").appending(certType)
        let profilesDir = tempDir.appending("profiles").appending(provType)

        // 3a) Pick certificate (.cer) and its matching .p12
        let cerCandidates = try listFiles(directory: certsDir, extensions: ["cer"]).sorted { $0.string < $1.string }
        guard let cerPath = try selectCertPath(candidates: cerCandidates, wantedId: wantedCertId) else {
            throw BuildError(message: "No certificate found for type '\(certType)'.")
        }
        let p12Path = FilePath(cerPath.string.replacingOccurrences(of: ".cer", with: ".p12"))
        if !FileManager.default.fileExists(atPath: p12Path.string) {
            let fileName = cerPath.lastComponent?.string ?? (cerPath.string as NSString).lastPathComponent
            throw BuildError(message: "Missing private key (.p12) for certificate '\(fileName)'.")
        }

        // 3b) Find provisioning profile for bundle id and platform
        let profileBaseName = profileFileBaseName(provType: provType, appIdentifier: appIdentifier, platform: platform)
        let profileExt = ["macos", "catalyst"].contains(platform) ? "provisionprofile" : "mobileprovision"
        let profileCandidates = try listFiles(directory: profilesDir, names: [profileBaseName], extensions: [profileExt])
        guard let profilePath = profileCandidates.sorted(by: { $0.string < $1.string }).last else {
            throw BuildError(message: "No provisioning profile found named '\(profileBaseName).\(profileExt)'.")
        }

        // 4) Import cert + key to keychain (idempotent)
        let keychainPath = resolveKeychainPath(from: keychainName)
        log("Installing certificate into keychain: \(keychainPath)")
        try await importIntoKeychain(itemPath: cerPath, keychainPath: keychainPath, itemPassword: "", keychainPassword: keychainPassword)
        try await importIntoKeychain(itemPath: p12Path, keychainPath: keychainPath, itemPassword: "", keychainPassword: keychainPassword)

        // 5) Install provisioning profile to Xcode directory
        let profileInfo = try await decodeProvisioningProfile(path: profilePath)
        let uuid = profileInfo.uuid
        let installedProfilePath = try installProvisioningProfile(src: profilePath, uuid: uuid, isMac: profileInfo.isMac)
        log.success("Installed provisioning profile: \(installedProfilePath)")

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
        setenv(envVarName(appIdentifier: appIdentifier, provType: provType, platform: platform, suffix: "profile-path"), installedProfilePath.string, 1)

        log.success("fastlane match (builtin) completed for \(appIdentifier) [\(type.rawValue)]")
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
    func listFiles(directory: FilePath, names: [String]? = nil, extensions: [String]) throws -> [FilePath] {
        guard FileManager.default.fileExists(atPath: directory.string) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory.string), includingPropertiesForKeys: nil)
        return urls.compactMap { url in
            let name = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension.lowercased()
            if extensions.contains(ext) && (names == nil || names!.contains(name)) {
                return FilePath(url.path)
            }
            return nil
        }
    }

    /// Select a certificate path from candidates, honoring MATCH_CERTIFICATE_ID if provided.
    func selectCertPath(candidates: [FilePath], wantedId: String?) throws -> FilePath? {
        guard !candidates.isEmpty else { return nil }
        if let id = wantedId {
            return candidates.first { $0.lastComponent?.string.contains(id) ?? false }
        }
        return candidates.last
    }

    /// Resolve a keychain logical name into an absolute file path.
    func resolveKeychainPath(from keychainName: String) -> FilePath {
        if keychainName.contains("/") { return FilePath(keychainName) }
        // Normalize typical names: login.keychain, login.keychain-db, or custom
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let libKeychains = FilePath(home).appending("Library/Keychains")
        if keychainName.hasSuffix(".keychain") || keychainName.hasSuffix(".keychain-db") {
            return libKeychains.appending(keychainName)
        } else {
            return libKeychains.appending("\(keychainName).keychain-db")
        }
    }

    /// Import a certificate/key file into a keychain and optionally set partition list.
    func importIntoKeychain(itemPath: FilePath, keychainPath: FilePath, itemPassword: String, keychainPassword: String?) async throws {
        let args = ["import", itemPath.string, "-k", keychainPath.string, "-P", itemPassword,
                    "-T", "/usr/bin/codesign", "-T", "/usr/bin/security", "-T", "/usr/bin/productbuild", "-T", "/usr/bin/productsign"]
        try await Tool(command: "/usr/bin/security", arguments: args, allowFailure: true).run()

        // Try to set partition list if password provided (ignore failures)
        if let kp = keychainPassword, !kp.isEmpty {
            let partArgs = [
                "set-key-partition-list",
                "-S", "apple-tool:,apple:,codesign:",
                "-s",
                "-k", kp,
                keychainPath.string
            ]
            try await Tool(command: "/usr/bin/security", arguments: partArgs, allowFailure: true).run(includeStandardError: false)
        }
    }

    /// Install a provisioning profile into the user profiles directory named by UUID.
    func installProvisioningProfile(src: FilePath, uuid: String, isMac: Bool) throws -> FilePath {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let profilesDir = FilePath(home).appending("Library/MobileDevice/Provisioning Profiles")
        try FileManager.default.createDirectory(atPath: profilesDir.string, withIntermediateDirectories: true)
        let ext = isMac ? ".provisionprofile" : ".mobileprovision"
        let dst = profilesDir.appending("\(uuid)\(ext)")
        if src.string != dst.string {
            // Copy
            if FileManager.default.fileExists(atPath: dst.string) {
                try FileManager.default.removeItem(atPath: dst.string)
            }
            try FileManager.default.copyItem(atPath: src.string, toPath: dst.string)
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
    func decodeProvisioningProfile(path: FilePath) async throws -> ProfileInfo {
        // security cms -D -i <path>
        let tool = Tool(command: "/usr/bin/security", arguments: ["cms", "-D", "-i", path.string])
        let xml = try await tool.runAndGetOutput(includeStandardError: false)
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
    func decryptMatchRepository(at dir: FilePath, password: String) async throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: dir.string) else { return }
        while let elem = enumerator.nextObject() as? String {
            let path = dir.appending(elem)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path.string, isDirectory: &isDir), isDir.boolValue { continue }
            let ext = (path.string as NSString).pathExtension.lowercased()
            if ["cer", "p12", "mobileprovision", "provisionprofile"].contains(ext) {
                try decryptFileInPlace(path: path, password: password)
            }
        }
    }

    /// Decrypt a single file in place if it uses match V1/V2 formats; ignore if already plaintext.
    func decryptFileInPlace(path: FilePath, password: String) throws {
        // Files are base64 text with prefixes: "match_encrypted_v2__" or "Salted__"
        let text = try String(contentsOfFile: path.string, encoding: .utf8)
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
        try decrypted.write(to: URL(fileURLWithPath: path.string))
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
