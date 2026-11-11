import XCTest
@testable import ServerKilnCore

final class MacReleaseTests: XCTestCase {
    func release(_ tag: String, draft: Bool = false, prerelease: Bool = false, url: String? = nil) throws -> MacGitHubRelease {
        let assets = url.map { [["name": "appcast.xml", "browser_download_url": $0]] } ?? []
        return try JSONDecoder().decode(MacGitHubRelease.self, from: JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "draft": draft, "prerelease": prerelease, "assets": assets
        ]))
    }
    func testVersionsAndUnpublishedReleases() throws {
        XCTAssertTrue(try release("v1.10.0").isNewer(than: "1.9.9"))
        XCTAssertFalse(try release("v1.0.2").isNewer(than: "1.0.2"))
        XCTAssertFalse(try release("v1.0.1").isNewer(than: "1.0.2"))
        XCTAssertFalse(try release("v2.0.0", prerelease: true).isNewer(than: "1.0.2"))
        XCTAssertFalse(try release("v2.0.0", draft: true).isNewer(than: "1.0.2"))
        XCTAssertFalse(try release("not-a-version").isNewer(than: "1.0.2"))
        XCTAssertFalse(try release("v2x0").isNewer(than: "1.0.2"))
        XCTAssertFalse(try release("v2.0.0-beta").isNewer(than: "1.0.2"))
    }
    func testFeedMustBeAnAssetFromOurRepository() throws {
        XCTAssertTrue(try release("v1.1.0", url: "https://github.com/Littleor/server-kiln/releases/download/v1.1.0/appcast.xml").hasUpdateFeed)
        for url in ["http://github.com/Littleor/server-kiln/releases/download/v1/appcast.xml",
                    "https://evil.example/appcast.xml",
                    "https://github.com/other/repo/releases/download/v1/appcast.xml"] {
            XCTAssertFalse(try release("v1.1.0", url: url).hasUpdateFeed)
        }
        XCTAssertFalse(try release("v1.1.0").hasUpdateFeed)
    }
}
