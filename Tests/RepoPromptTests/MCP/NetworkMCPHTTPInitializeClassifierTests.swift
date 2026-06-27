import Foundation
@testable import RepoPrompt
import XCTest

final class NetworkMCPHTTPInitializeClassifierTests: XCTestCase {
    func testAcceptsSingleInitializeRequestWithStringID() {
        let body = jsonData([
            "jsonrpc": "2.0",
            "id": "init-1",
            "method": "initialize"
        ])

        XCTAssertTrue(MCPNetworkHTTPInitializeClassifier.isSingleInitializeRequest(body))
    }

    func testAcceptsSingleInitializeRequestWithIntegralNumericID() {
        let body = jsonData([
            "jsonrpc": "2.0",
            "id": 7,
            "method": "initialize"
        ])

        XCTAssertTrue(MCPNetworkHTTPInitializeClassifier.isSingleInitializeRequest(body))
    }

    func testRejectsInitializeWhenJSONRPCFieldIsAbsent() {
        let body = jsonData([
            "id": 1,
            "method": "initialize"
        ])

        XCTAssertFalse(MCPNetworkHTTPInitializeClassifier.isSingleInitializeRequest(body))
    }

    func testRejectsBatchInitialize() {
        let body = jsonData([
            ["jsonrpc": "2.0", "id": 1, "method": "initialize"]
        ])

        XCTAssertFalse(MCPNetworkHTTPInitializeClassifier.isSingleInitializeRequest(body))
    }

    func testRejectsInitializeNotificationWithoutID() {
        let body = jsonData([
            "jsonrpc": "2.0",
            "method": "initialize"
        ])

        XCTAssertFalse(MCPNetworkHTTPInitializeClassifier.isSingleInitializeRequest(body))
    }

    func testRejectsInvalidRequestIDs() {
        let invalidIDs: [Any] = [NSNull(), true, 1.25]
        for id in invalidIDs {
            let body = jsonData([
                "jsonrpc": "2.0",
                "id": id,
                "method": "initialize"
            ])

            XCTAssertFalse(MCPNetworkHTTPInitializeClassifier.isSingleInitializeRequest(body), "id=\(id) should be rejected")
        }
    }

    func testRejectsResponsesAndNonInitializeRequests() {
        XCTAssertFalse(MCPNetworkHTTPInitializeClassifier.isSingleInitializeRequest(jsonData([
            "jsonrpc": "2.0",
            "id": 1,
            "result": [:]
        ])))
        XCTAssertFalse(MCPNetworkHTTPInitializeClassifier.isSingleInitializeRequest(jsonData([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list"
        ])))
    }

    func testRejectsInvalidJSONEmptyDataAndInvalidJSONRPCVersion() {
        XCTAssertFalse(MCPNetworkHTTPInitializeClassifier.isSingleInitializeRequest(Data()))
        XCTAssertFalse(MCPNetworkHTTPInitializeClassifier.isSingleInitializeRequest(Data("not json".utf8)))
        XCTAssertFalse(MCPNetworkHTTPInitializeClassifier.isSingleInitializeRequest(jsonData([
            "jsonrpc": "1.0",
            "id": 1,
            "method": "initialize"
        ])))
    }

    private func jsonData(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
