import XCTest
import CodexTouchCore

final class JSONRPCFixtureTests: XCTestCase {
    func testCodexResponseWithoutJSONRPCVersionDecodes() throws {
        let data = Data(#"{"id":1,"result":{"codexHome":"/tmp/profile"}}"#.utf8)
        let message = try JSONDecoder().decode(JSONRPCMessage.self, from: data)
        XCTAssertNil(message.jsonrpc)
        XCTAssertEqual(message.id, 1)
    }

    func testOutgoingCodexRequestOmitsJSONRPCVersion() throws {
        let request = JSONRPCMessage(id: 1, method: "account/read", params: .object([:]))
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["jsonrpc"])
        XCTAssertEqual(object["method"] as? String, "account/read")
    }

    func testErrorFixturePreservesOnlySafeRPCMetadata() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "error", withExtension: "json", subdirectory: "Fixtures/AppServer"))
        let message = try JSONDecoder().decode(JSONRPCMessage.self, from: Data(contentsOf: url))
        XCTAssertEqual(message.id, 7)
        XCTAssertEqual(message.error?.code, -32601)
        XCTAssertNil(message.result)
    }
}
