import Foundation

/// A `URLProtocol` that intercepts every request and answers from a
/// per-run (test-scoped) registry of stubbed responses, keyed by request
/// path suffix.
///
/// Handlers are registered per `runId` (a unique string tag attached to
/// every outgoing request via `makeStubbedSession(runId:)`), rather than as
/// shared global state — this avoids cross-test races where one test's
/// handler matches another test's concurrently in-flight request.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        let status: Int
        let headers: [String: String]
        let body: Data
        let responseURL: URL?

        init(status: Int, headers: [String: String] = [:], body: Data, responseURL: URL? = nil) {
            self.status = status
            self.headers = headers
            self.body = body
            self.responseURL = responseURL
        }
    }

    private static let lock = NSLock()
    /// Per-run (test-scoped) ordered list of (path-suffix matcher, stub) pairs.
    nonisolated(unsafe) private static var handlersByRun: [String: [(String, Stub)]] = [:]

    static let runIdHeader = "X-Test-Run-Id"

    static func addHandler(runId: String, pathSuffix: String, stub: Stub) {
        lock.lock()
        handlersByRun[runId, default: []].append((pathSuffix, stub))
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let runId = request.value(forHTTPHeaderField: StubURLProtocol.runIdHeader) ?? ""
        let path = request.url?.path ?? ""

        StubURLProtocol.lock.lock()
        let match = StubURLProtocol.handlersByRun[runId]?.first(where: { path.hasSuffix($0.0) })
        StubURLProtocol.lock.unlock()

        guard let (_, stub) = match else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }

        let responseURL = stub.responseURL ?? request.url!
        let httpResponse = HTTPURLResponse(
            url: responseURL,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Build a `URLSession` that routes through `StubURLProtocol` and tags every
/// outgoing request with a unique run id, so stub registrations for this test
/// never collide with those of a concurrently running test.
func makeStubbedSession(runId: String = UUID().uuidString) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    config.httpAdditionalHeaders = [StubURLProtocol.runIdHeader: runId]
    return URLSession(configuration: config)
}
