import Foundation

extension URL {
    /// The file system path of this URL, with percent-encoding removed and without the `file://` scheme.
    ///
    /// Use it for tool arguments and in messages. `absoluteString` and string interpolation of a URL give
    /// `file:///My%20Dir/…`, which tools and users do not expect.
    public var filePath: String {
        path(percentEncoded: false)
    }
}
