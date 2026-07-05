import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Error surface of `URLDownloader`. Each case renders a specific, user-facing
/// detail so a failed `--url` fetch explains itself: rejected scheme, timeout,
/// HTTP status, size limit, or transport failure.
public enum URLDownloadError: Error, CustomStringConvertible, Equatable, Sendable {
    case unsupportedScheme(String)
    case timeout(seconds: Int)
    case httpStatus(Int)
    case tooLarge(limitBytes: Int)
    case network(String)

    public var description: String {
        switch self {
        case .unsupportedScheme(let scheme):
            return "unsupported URL scheme '\(scheme)': only http and https are allowed"
        case .timeout(let seconds):
            return "download timed out after \(seconds)s"
        case .httpStatus(let code):
            return "server responded with HTTP \(code)"
        case .tooLarge(let limit):
            return "response exceeds the download limit of \(limit / (1024 * 1024)) MB"
        case .network(let detail):
            return "network error: \(detail)"
        }
    }
}

/// Downloads one http(s) URL into memory, synchronously, with hard limits:
/// a per-request timeout, a total wall-clock budget, and a maximum body size
/// enforced while streaming (the transfer is cancelled as soon as the limit is
/// crossed, not after the fact). Every scheme other than http/https is rejected
/// before any I/O. Mirrors the bounded-wait posture of `ProcessRunner`: a hung
/// or hostile server can never stall a run past `totalTimeout`.
public struct URLDownloader: Sendable {
    public let maxBytes: Int
    public let requestTimeout: TimeInterval
    public let totalTimeout: TimeInterval

    public init(
        maxBytes: Int = 10 * 1024 * 1024,
        requestTimeout: TimeInterval = 30,
        totalTimeout: TimeInterval = 120
    ) {
        self.maxBytes = maxBytes
        self.requestTimeout = requestTimeout
        self.totalTimeout = totalTimeout
    }

    // MARK: - Policy checks (pure; unit-tested without network)

    /// nil when the URL's scheme is http or https (any case); the error otherwise.
    public static func schemeError(of url: URL) -> URLDownloadError? {
        let scheme = url.scheme?.lowercased() ?? ""
        return (scheme == "http" || scheme == "https") ? nil : .unsupportedScheme(scheme)
    }

    /// nil when the HTTP status is acceptable (200...299); the error otherwise.
    public static func statusError(_ statusCode: Int) -> URLDownloadError? {
        (200...299).contains(statusCode) ? nil : .httpStatus(statusCode)
    }

    /// nil while `byteCount` (announced or accumulated) fits the limit. Negative
    /// counts mean "length unknown" and pass; the streaming cap still applies.
    public static func sizeError(byteCount: Int64, limit: Int) -> URLDownloadError? {
        byteCount > Int64(limit) ? .tooLarge(limitBytes: limit) : nil
    }

    // MARK: - Download

    public func download(_ url: URL) throws -> Data {
        if let error = Self.schemeError(of: url) { throw error }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = totalTimeout

        let collector = Collector(maxBytes: maxBytes)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }

        let task = session.dataTask(with: url)
        task.resume()

        // Backstop: URLSession's resource timeout should always fire first; the
        // grace period only guarantees this synchronous call can never hang.
        guard collector.wait(seconds: totalTimeout + 5) != .timedOut else {
            task.cancel()
            throw URLDownloadError.timeout(seconds: Int(totalTimeout))
        }
        return try collector.result(timeoutSeconds: Int(totalTimeout))
    }

    /// Accumulates the body on the session's delegate queue, cancelling the task
    /// the moment a policy check fails. Only closure-free delegate methods are
    /// implemented so the witnesses match on both Darwin and corelibs Foundation.
    /// State is lock-guarded; `done` is signalled exactly once on completion.
    private final class Collector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let maxBytes: Int
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var body = Data()
        private var failure: URLDownloadError?
        private var transportError: Error?

        init(maxBytes: Int) {
            self.maxBytes = maxBytes
        }

        func wait(seconds: TimeInterval) -> DispatchTimeoutResult {
            done.wait(timeout: .now() + seconds)
        }

        func result(timeoutSeconds: Int) throws -> Data {
            lock.lock()
            defer { lock.unlock() }
            // A policy failure caused the cancel, so it outranks the resulting
            // NSURLErrorCancelled transport error.
            if let failure { throw failure }
            if let transportError {
                if let urlError = transportError as? URLError, urlError.code == .timedOut {
                    throw URLDownloadError.timeout(seconds: timeoutSeconds)
                }
                throw URLDownloadError.network(transportError.localizedDescription)
            }
            return body
        }

        /// Status outside 200...299, or an announced length over the cap.
        private func responseError(_ response: URLResponse?) -> URLDownloadError? {
            guard let response else { return nil }
            if let http = response as? HTTPURLResponse,
               let statusError = URLDownloader.statusError(http.statusCode) {
                return statusError
            }
            return URLDownloader.sizeError(byteCount: response.expectedContentLength, limit: maxBytes)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            lock.lock()
            if failure == nil { failure = responseError(dataTask.response) }
            if failure == nil {
                body.append(chunk)
                if body.count > maxBytes { failure = .tooLarge(limitBytes: maxBytes) }
            }
            let shouldCancel = failure != nil
            lock.unlock()
            if shouldCancel { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            // Re-check on completion: an error response with an empty body never
            // reaches `didReceive`.
            if failure == nil { failure = responseError(task.response) }
            if failure == nil, let error { transportError = error }
            lock.unlock()
            done.signal()
        }
    }
}
