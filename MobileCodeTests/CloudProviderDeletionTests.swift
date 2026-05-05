import Foundation
import XCTest
@testable import CodeAgentsMobile

final class CloudProviderDeletionTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testDigitalOceanDeleteServerUsesDropletEndpoint() async throws {
        var capturedRequest: URLRequest?
        StubURLProtocol.requestHandler = { request in
            capturedRequest = request
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        let service = DigitalOceanService(apiToken: "do-token", session: makeSession())

        try await service.deleteServer(id: "123456")

        XCTAssertEqual(capturedRequest?.httpMethod, "DELETE")
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://api.digitalocean.com/v2/droplets/123456")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer do-token")
    }

    func testDigitalOceanValidateTokenUsesDropletEndpointForScopedTokens() async throws {
        var capturedRequest: URLRequest?
        StubURLProtocol.requestHandler = { request in
            capturedRequest = request
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"droplets":[]}"#.utf8)
            )
        }
        let service = DigitalOceanService(apiToken: "do-token", session: makeSession())

        let isValid = try await service.validateToken()

        XCTAssertTrue(isValid)
        XCTAssertEqual(capturedRequest?.httpMethod, "GET")
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://api.digitalocean.com/v2/droplets?per_page=1")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer do-token")
    }

    func testDigitalOceanValidateTokenMapsUnauthorizedToInvalidToken() async throws {
        StubURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        let service = DigitalOceanService(apiToken: "do-token", session: makeSession())

        do {
            _ = try await service.validateToken()
            XCTFail("Expected invalidToken")
        } catch CloudProviderError.invalidToken {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHetznerDeleteServerUsesServerEndpoint() async throws {
        var capturedRequest: URLRequest?
        StubURLProtocol.requestHandler = { request in
            capturedRequest = request
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"action":{"id":1}}"#.utf8)
            )
        }
        let service = HetznerCloudService(apiToken: "hc-token", session: makeSession())

        try await service.deleteServer(id: "987654")

        XCTAssertEqual(capturedRequest?.httpMethod, "DELETE")
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://api.hetzner.cloud/v1/servers/987654")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer hc-token")
    }

    func testDeleteServerMaps404ToServerNotFound() async throws {
        StubURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        let service = DigitalOceanService(apiToken: "do-token", session: makeSession())

        do {
            try await service.deleteServer(id: "missing")
            XCTFail("Expected serverNotFound")
        } catch CloudProviderError.serverNotFound {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class StubURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
