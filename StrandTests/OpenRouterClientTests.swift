import Foundation
import XCTest
@testable import Strand

private final class OpenRouterURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var responseBody = ""
    nonisolated(unsafe) static var status = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static func session(body: String, status: Int = 200) -> URLSession {
        requests = []
        responseBody = body
        Self.status = status
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Self.self]
        return URLSession(configuration: config)
    }
}

final class OpenRouterClientTests: XCTestCase {
    func testChatUsesOpenRouterEndpointAndBearerKeyWithFullModelID() async throws {
        let session = OpenRouterURLProtocol.session(body: #"{"choices":[{"message":{"content":"Rest today."}}]}"#)
        defer { session.invalidateAndCancel() }
        let reply = try await AIProvider.openRouter.client.send(key: "test-key", model: "z-ai/glm-5.3-flash",
            systemPrompt: "Coach", messages: [(.user, "How should I train?")], session: session)
        XCTAssertEqual(reply, "Rest today.")
        let request = try XCTUnwrap(OpenRouterURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let json = try requestJSON(request)
        XCTAssertEqual((json["provider"] as? [String: Bool])?["zdr"], true)
        XCTAssertEqual(json["model"] as? String, "z-ai/glm-5.3-flash")
        XCTAssertEqual(json["max_tokens"] as? Int, 4096)
        XCTAssertEqual((json["messages"] as? [[String: String]])?.last?["content"], "How should I train?")
    }

    func testStreamingChatUsesOpenRouterAndReassemblesTextDeltas() async throws {
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"Rest\"}}]}\n\n"
            + "data: {\"choices\":[{\"delta\":{\"content\":\" today.\"}}]}\n\n"
            + "data: [DONE]\n\n"
        let session = OpenRouterURLProtocol.session(body: body)
        defer { session.invalidateAndCancel() }
        var reply = ""
        try await AIProvider.openRouter.client.stream(key: "test-key", model: "z-ai/glm-5.3-flash",
            systemPrompt: "Coach", messages: [(.user, "Hello")], session: session) { reply += $0 }
        XCTAssertEqual(reply, "Rest today.")
        XCTAssertEqual(OpenRouterURLProtocol.requests.first?.url?.absoluteString,
                       "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(OpenRouterURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer test-key")
        let request = try XCTUnwrap(OpenRouterURLProtocol.requests.first)
        XCTAssertEqual((try requestJSON(request)["provider"] as? [String: Bool])?["zdr"], true)
    }

    func testZDRPolicySurvivesAllParameterAndStreamingVariants() {
        for modern in [false, true] {
            for stream in [false, true] {
                let body = OpenAIClient(provider: .openRouter).requestBody(
                    model: "vendor/model", wire: [], modernParams: modern, stream: stream)
                XCTAssertEqual((body["provider"] as? [String: Bool])?["zdr"], true)
                XCTAssertEqual(body[modern ? "max_completion_tokens" : "max_tokens"] as? Int, 4096)
            }
        }
        XCTAssertNil(OpenAIClient().requestBody(model: "gpt-4", wire: [])["provider"])
    }

    func testNoZDREndpointFailsWithoutRelaxingPolicy() async throws {
        let session = OpenRouterURLProtocol.session(
            body: #"{"error":{"message":"No endpoints found matching your data policy"}}"#, status: 404)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await AIProvider.openRouter.client.send(key: "test-key", model: "vendor/model",
                systemPrompt: "Coach", messages: [(.user, "Hello")], session: session)
            XCTFail("Expected routing to fail")
        } catch AICoachError.server(let code, _) {
            XCTAssertEqual(code, 404)
        }
        XCTAssertEqual(OpenRouterURLProtocol.requests.count, 1)
        let request = try XCTUnwrap(OpenRouterURLProtocol.requests.first)
        XCTAssertEqual((try requestJSON(request)["provider"] as? [String: Bool])?["zdr"], true)
    }

    private func requestJSON(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody { data = body }
        else {
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                bytes.append(buffer, count: count)
            }
            data = bytes
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testCatalogueUsesOpenRouterAndPreservesPrices() async throws {
        let session = OpenRouterURLProtocol.session(body: OpenRouterModelTests.fixture)
        defer { session.invalidateAndCancel() }
        let models = try await AIProvider.openRouter.client.fetchModelOptions(key: "test-key", session: session)
        XCTAssertEqual(models.first?.priceFigures?.input, "$0.15")
        let request = try XCTUnwrap(OpenRouterURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/models")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    }

    func testInsufficientCreditsDoesNotClaimKeyRejection() async {
        let session = OpenRouterURLProtocol.session(body: #"{"error":{"message":"Insufficient credits"}}"#, status: 402)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await AIProvider.openRouter.client.send(key: "test-key", model: "z-ai/glm-5.3-flash",
                systemPrompt: "Coach", messages: [(.user, "Hello")], session: session)
            XCTFail("Expected a credit error")
        } catch AICoachError.server(let code, let detail) {
            XCTAssertEqual(code, 402)
            XCTAssertEqual(detail, "Insufficient credits")
        } catch { XCTFail("Unexpected error: \(error)") }
    }
}
