import Foundation
import Testing
@testable import KittymgrCore

/// Policy checks of the URL download path, tested without any network I/O.
struct URLDownloaderTests {
    @Test func schemeAllowsOnlyHTTPAndHTTPS() {
        #expect(URLDownloader.schemeError(of: URL(string: "http://example.com/a")!) == nil)
        #expect(URLDownloader.schemeError(of: URL(string: "https://example.com/a")!) == nil)
        #expect(URLDownloader.schemeError(of: URL(string: "HTTPS://EXAMPLE.COM/A")!) == nil)

        #expect(URLDownloader.schemeError(of: URL(string: "file:///etc/passwd")!)
            == .unsupportedScheme("file"))
        #expect(URLDownloader.schemeError(of: URL(string: "ftp://host/file")!)
            == .unsupportedScheme("ftp"))
        #expect(URLDownloader.schemeError(of: URL(string: "data:text/plain,hi")!)
            == .unsupportedScheme("data"))
        #expect(URLDownloader.schemeError(of: URL(string: "gopher://host/x")!)
            == .unsupportedScheme("gopher"))
    }

    @Test func statusAcceptsOnly2xx() {
        #expect(URLDownloader.statusError(200) == nil)
        #expect(URLDownloader.statusError(204) == nil)
        #expect(URLDownloader.statusError(299) == nil)

        #expect(URLDownloader.statusError(199) == .httpStatus(199))
        #expect(URLDownloader.statusError(301) == .httpStatus(301))
        #expect(URLDownloader.statusError(404) == .httpStatus(404))
        #expect(URLDownloader.statusError(500) == .httpStatus(500))
    }

    @Test func sizeLimitEnforcedAndUnknownLengthPasses() {
        let limit = 10 * 1024 * 1024
        #expect(URLDownloader.sizeError(byteCount: 0, limit: limit) == nil)
        #expect(URLDownloader.sizeError(byteCount: Int64(limit), limit: limit) == nil)
        #expect(URLDownloader.sizeError(byteCount: Int64(limit) + 1, limit: limit)
            == .tooLarge(limitBytes: limit))
        // -1 is URLResponse's "unknown length"; the streaming cap still applies.
        #expect(URLDownloader.sizeError(byteCount: -1, limit: limit) == nil)
    }

    @Test func errorDescriptionsNameTheCause() {
        #expect("\(URLDownloadError.unsupportedScheme("file"))".contains("file"))
        #expect("\(URLDownloadError.unsupportedScheme("file"))".contains("http"))
        #expect("\(URLDownloadError.timeout(seconds: 120))".contains("120"))
        #expect("\(URLDownloadError.httpStatus(404))".contains("404"))
        #expect("\(URLDownloadError.tooLarge(limitBytes: 10 * 1024 * 1024))".contains("10 MB"))
        #expect("\(URLDownloadError.network("dns failure"))".contains("dns failure"))
    }

    @Test func defaultsMatchTheReleasePolicy() {
        let downloader = URLDownloader()
        #expect(downloader.maxBytes == 10 * 1024 * 1024)
        #expect(downloader.requestTimeout == 30)
        #expect(downloader.totalTimeout == 120)
    }

    @Test func downloadRejectsNonHTTPSchemeBeforeAnyIO() {
        #expect(throws: URLDownloadError.unsupportedScheme("file")) {
            try URLDownloader().download(URL(string: "file:///etc/passwd")!)
        }
    }
}
