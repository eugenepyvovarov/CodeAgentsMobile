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

    /// Real DO payloads often set image.slug to null for custom/retired base images.
    func testDigitalOceanListServersAcceptsNullImageSlug() async throws {
        let payload = """
        {
          "droplets": [{
            "id": 568984575,
            "name": "op",
            "status": "active",
            "networks": {
              "v4": [
                {"ip_address": "134.122.65.132", "netmask": "255.255.240.0", "gateway": "134.122.64.1", "type": "public"}
              ]
            },
            "region": {"name": "Frankfurt", "slug": "fra1", "available": true},
            "image": {"id": 195932981, "name": "24.04 (LTS) x64", "slug": null},
            "size": {"slug": "s-1vcpu-1gb"}
          }]
        }
        """
        var capturedURL: URL?
        StubURLProtocol.requestHandler = { request in
            capturedURL = request.url
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(payload.utf8)
            )
        }
        let service = DigitalOceanService(apiToken: "do-token", session: makeSession())

        let servers = try await service.listServers()

        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].id, "568984575")
        XCTAssertEqual(servers[0].name, "op")
        XCTAssertEqual(servers[0].publicIP, "134.122.65.132")
        XCTAssertEqual(servers[0].imageInfo, "24.04 (LTS) x64")
        XCTAssertEqual(servers[0].sizeInfo, "s-1vcpu-1gb")
        XCTAssertEqual(capturedURL?.absoluteString, "https://api.digitalocean.com/v2/droplets?per_page=200")
    }

    /// New droplets can temporarily omit networks.v4; DO image.slug is nullable in the OpenAPI schema.
    func testDigitalOceanListServersAcceptsMissingNetworksV4() async throws {
        let payload = """
        {
          "droplets": [{
            "id": 1,
            "name": "bootstrapping",
            "status": "new",
            "networks": {},
            "region": {"name": "New York 3", "slug": "nyc3"},
            "image": {"name": "Ubuntu", "slug": null},
            "size": {"slug": "s-1vcpu-1gb"}
          }]
        }
        """
        StubURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(payload.utf8)
            )
        }
        let service = DigitalOceanService(apiToken: "do-token", session: makeSession())

        let servers = try await service.listServers()

        XCTAssertEqual(servers.count, 1)
        XCTAssertNil(servers[0].publicIP)
        XCTAssertEqual(servers[0].imageInfo, "Ubuntu")
    }

    func testDigitalOceanListSizesRequestsFullPage() async throws {
        var capturedURL: URL?
        let payload = """
        {
          "sizes": [{
            "slug": "s-1vcpu-1gb",
            "memory": 1024,
            "vcpus": 1,
            "disk": 25,
            "price_monthly": 6,
            "available": true,
            "regions": ["nyc3"]
          }]
        }
        """
        StubURLProtocol.requestHandler = { request in
            capturedURL = request.url
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(payload.utf8)
            )
        }
        let service = DigitalOceanService(apiToken: "do-token", session: makeSession())

        let sizes = try await service.listSizes()

        XCTAssertEqual(sizes.count, 1)
        XCTAssertEqual(sizes[0].id, "s-1vcpu-1gb")
        XCTAssertEqual(capturedURL?.absoluteString, "https://api.digitalocean.com/v2/sizes?per_page=200")
    }

    /// After 2026-07-01 Hetzner removed `datacenter` from server responses; use top-level `location`.
    func testHetznerListServersAcceptsLocationWithoutDatacenter() async throws {
        let payload = """
        {
          "servers": [{
            "id": 42,
            "name": "app-1",
            "status": "running",
            "public_net": {
              "ipv4": {"ip": "203.0.113.10"},
              "ipv6": null
            },
            "private_net": [],
            "location": {"id": 1, "name": "fsn1", "city": "Falkenstein", "country": "DE"},
            "image": {"id": 100, "name": "ubuntu-24.04", "description": "Ubuntu 24.04"},
            "server_type": {"name": "cpx11"}
          }]
        }
        """
        var capturedURL: URL?
        StubURLProtocol.requestHandler = { request in
            capturedURL = request.url
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(payload.utf8)
            )
        }
        let service = HetznerCloudService(apiToken: "hc-token", session: makeSession())

        let servers = try await service.listServers()

        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].id, "42")
        XCTAssertEqual(servers[0].publicIP, "203.0.113.10")
        XCTAssertEqual(servers[0].region, "fsn1")
        XCTAssertEqual(servers[0].imageInfo, "ubuntu-24.04")
        XCTAssertEqual(servers[0].sizeInfo, "cpx11")
        XCTAssertEqual(capturedURL?.absoluteString, "https://api.hetzner.cloud/v1/servers?per_page=50")
    }

    /// Hetzner may return null image and omit private_net on some servers.
    func testHetznerListServersAcceptsNullImageAndMissingPrivateNet() async throws {
        let payload = """
        {
          "servers": [{
            "id": 7,
            "name": "volume-only",
            "status": "off",
            "public_net": {"ipv4": null, "ipv6": null},
            "location": {"name": "nbg1"},
            "image": null,
            "server_type": {"name": "cx22"}
          }]
        }
        """
        StubURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(payload.utf8)
            )
        }
        let service = HetznerCloudService(apiToken: "hc-token", session: makeSession())

        let servers = try await service.listServers()

        XCTAssertEqual(servers.count, 1)
        XCTAssertNil(servers[0].publicIP)
        XCTAssertNil(servers[0].privateIP)
        XCTAssertEqual(servers[0].region, "nbg1")
        XCTAssertEqual(servers[0].imageInfo, "Unknown image")
        XCTAssertEqual(servers[0].sizeInfo, "cx22")
    }

    /// Prefer per-location availability when filtering server types.
    func testHetznerListSizesFiltersUnavailableTypes() async throws {
        let payload = """
        {
          "server_types": [
            {
              "id": 1,
              "name": "cpx11",
              "description": "CPX 11",
              "cores": 2,
              "memory": 2.0,
              "disk": 40,
              "prices": [{"price_monthly": {"gross": "4.90"}}],
              "deprecated": false,
              "deprecation": null,
              "locations": [
                {"id": 1, "name": "fsn1", "available": true, "recommended": true}
              ]
            },
            {
              "id": 2,
              "name": "cx11",
              "description": "CX 11 legacy",
              "cores": 1,
              "memory": 2.0,
              "disk": 20,
              "prices": [{"price_monthly": {"gross": "3.29"}}],
              "deprecated": false,
              "deprecation": null,
              "locations": [
                {"id": 1, "name": "fsn1", "available": false, "recommended": false}
              ]
            },
            {
              "id": 3,
              "name": "cx21",
              "description": "CX 21 retired",
              "cores": 2,
              "memory": 4.0,
              "disk": 40,
              "prices": [{"price_monthly": {"gross": "5.83"}}],
              "deprecated": true,
              "deprecation": {"announced": "2024-01-01", "unavailable_after": "2024-06-01"},
              "locations": []
            }
          ]
        }
        """
        StubURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(payload.utf8)
            )
        }
        let service = HetznerCloudService(apiToken: "hc-token", session: makeSession())

        let sizes = try await service.listSizes()

        XCTAssertEqual(sizes.map(\.id), ["cpx11"])
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
