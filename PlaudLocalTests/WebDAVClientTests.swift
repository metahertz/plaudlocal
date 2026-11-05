import XCTest
@testable import PlaudLocal

final class WebDAVClientTests: XCTestCase {
    func test_mkcol_and_put() async throws {
        let stub = StubURLProtocol.handler
        StubURLProtocol.handler = { request in
            let method = request.httpMethod ?? ""
            if method == "MKCOL" {
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data())
            }
            if method == "PUT" {
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.handler = stub }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        var client = WebDAVClient(
            baseURL: URL(string: "https://cloud.example/remote.php/dav/files/u/")!,
            username: "u",
            password: "p",
            session: session
        )
        try await client.ensureCollection("PlaudLocal")
        try await client.upload(data: Data("hi".utf8), toPath: "PlaudLocal/note.txt")
    }
}

final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
