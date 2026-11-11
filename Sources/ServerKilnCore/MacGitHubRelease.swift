import Foundation

/// Metadata for the public Mac release channel; drafts and prereleases are
/// never offered even if a server returns them unexpectedly.
public struct MacGitHubRelease: Decodable {
    public struct Asset: Decodable {
        public var name: String
        public var browser_download_url: URL
    }
    public var tag_name: String
    public var draft: Bool
    public var prerelease: Bool
    public var assets: [Asset]

    public var hasUpdateFeed: Bool {
        !draft && !prerelease && assets.contains {
            $0.name == "appcast.xml" && $0.browser_download_url.scheme == "https"
            && $0.browser_download_url.host == "github.com"
            && $0.browser_download_url.path.hasPrefix("/Littleor/server-kiln/releases/download/")
            && $0.browser_download_url.lastPathComponent == "appcast.xml"
        }
    }

    public func isNewer(than installed: String) -> Bool {
        guard !draft, !prerelease else { return false }
        let version = tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name
        guard version.range(of: #"^[0-9]+(\.[0-9]+){1,2}$"#, options: .regularExpression) != nil else { return false }
        return version.compare(installed, options: .numeric) == .orderedDescending
    }
}
