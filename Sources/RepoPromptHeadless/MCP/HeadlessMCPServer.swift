import Foundation

final class HeadlessMCPServer {
    private let configurationStore: HeadlessConfigurationStore

    init(configurationStore: HeadlessConfigurationStore) {
        self.configurationStore = configurationStore
    }

    func handle(frame: Data) -> HeadlessRPCAction {
        do {
            let object = try HeadlessJSONRPC.requestObject(from: frame)
            return handle(object: object)
        } catch let error as HeadlessJSONRPCError {
            return HeadlessRPCAction(
                responseData: HeadlessJSONRPC.errorResponse(id: NSNull(), code: -32600, message: error.localizedDescription),
                shouldExit: false
            )
        } catch {
            return HeadlessRPCAction(
                responseData: HeadlessJSONRPC.errorResponse(id: NSNull(), code: -32700, message: "Parse error: \(error.localizedDescription)"),
                shouldExit: false
            )
        }
    }

    private func handle(object: [String: Any]) -> HeadlessRPCAction {
        let hasID = object.keys.contains("id")
        let id = object["id"] ?? NSNull()
        guard object["jsonrpc"] as? String == "2.0" else {
            return requestError(hasID: hasID, id: id, code: -32600, message: "Only JSON-RPC 2.0 requests are supported.")
        }
        guard let method = object["method"] as? String, !method.isEmpty else {
            return requestError(hasID: hasID, id: id, code: -32600, message: "JSON-RPC request is missing a method.")
        }

        switch method {
        case "initialize":
            return requestResult(hasID: hasID, id: id, result: initializeResult())
        case "notifications/initialized":
            return HeadlessRPCAction(responseData: nil, shouldExit: false)
        case "ping":
            return requestResult(hasID: hasID, id: id, result: [:])
        case "tools/list":
            return requestResult(hasID: hasID, id: id, result: ["tools": []])
        case "shutdown":
            return requestResult(hasID: hasID, id: id, result: NSNull(), shouldExit: true)
        case "exit":
            if hasID {
                return requestResult(hasID: true, id: id, result: NSNull(), shouldExit: true)
            }
            return HeadlessRPCAction(responseData: nil, shouldExit: true)
        default:
            return requestError(hasID: hasID, id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func initializeResult() -> [String: Any] {
        let configuredRootCount = (try? configurationStore.loadOrCreate().allowedRoots.count) ?? 0
        return [
            "protocolVersion": HeadlessVersion.mcpProtocolVersion,
            "capabilities": [
                "tools": [:]
            ],
            "serverInfo": [
                "name": HeadlessVersion.displayName,
                "version": HeadlessVersion.marketingVersion
            ],
            "instructions": "RepoPrompt Headless Slice 5A is running fail-closed over direct stdio. Configure allowed roots with `repoprompt-headless config roots add /absolute/path --name NAME`. MCP tools are intentionally not enabled yet.",
            "headless": [
                "configuredRootCount": configuredRootCount,
                "stateDirectory": configurationStore.paths.rootDirectory.path,
                "safeToolsEnabled": false
            ]
        ]
    }

    private func requestResult(hasID: Bool, id: Any, result: Any, shouldExit: Bool = false) -> HeadlessRPCAction {
        guard hasID else {
            return HeadlessRPCAction(responseData: nil, shouldExit: shouldExit)
        }
        return HeadlessRPCAction(responseData: HeadlessJSONRPC.response(id: id, result: result), shouldExit: shouldExit)
    }

    private func requestError(hasID: Bool, id: Any, code: Int, message: String) -> HeadlessRPCAction {
        guard hasID else {
            return HeadlessRPCAction(responseData: nil, shouldExit: false)
        }
        return HeadlessRPCAction(responseData: HeadlessJSONRPC.errorResponse(id: id, code: code, message: message), shouldExit: false)
    }
}
