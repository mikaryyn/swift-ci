extension Xcode {
    public struct BuildSettings {
        public let all: [String: String]

        public func get(key: String, fallback: String? = nil) throws -> String {
            guard let result = all[key] ?? fallback else {
                throw BuildError(message: "Failed to find \(key) build setting")
            }
            return result
        }

        public func marketingVersion(fallback: String? = nil) throws -> String {
            try get(key: "MARKETING_VERSION", fallback: fallback)
        }

        public var provisioningProfileSpecifier: String {
            get throws {
                try get(key: "PROVISIONING_PROFILE_SPECIFIER")
            }
        }
    }
}
