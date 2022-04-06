extension Xcode {
    public struct BuildSettings: Decodable {
        public var all: [String: String] { buildSettings }

        public func get(key: String) throws -> String {
            guard let result = all[key] else {
                throw BuildError(message: "Failed to find \(key) build setting")
            }
            return result
        }

        public func get(key: String, fallback: String) -> String {
            all[key] ?? fallback
        }

        public var marketingVersion: String {
            get throws  { try get(key: "MARKETING_VERSION") }
        }

        public var provisioningProfileSpecifier: String {
            get throws { try get(key: "PROVISIONING_PROFILE_SPECIFIER") }
        }

        public var builtProductsDir: String {
            get throws { try get(key: "BUILT_PRODUCTS_DIR") }
        }

        public static let empty = BuildSettings(action: "", buildSettings: [:])

        private enum CodingKeys: CodingKey {
            case action, buildSettings
        }

        private var action: String
        private var buildSettings: [String: String]
    }
}
