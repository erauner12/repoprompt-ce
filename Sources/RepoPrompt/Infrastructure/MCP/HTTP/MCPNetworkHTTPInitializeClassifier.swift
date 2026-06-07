import Foundation

/// Admission-only classifier for deciding whether a sessionless Network MCP POST may allocate a session.
///
/// This is intentionally narrower than a general JSON-RPC parser: it only accepts a single
/// JSON-RPC 2.0 request object whose method is `initialize` and whose `id` is a string or
/// integral number. Batches, notifications, responses, invalid JSON, and non-initialize
/// requests are rejected closed before session creation.
enum MCPNetworkHTTPInitializeClassifier {
    static func isSingleInitializeRequest(_ body: Data) -> Bool {
        guard !body.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: body, options: []),
              let object = json as? [String: Any]
        else {
            return false
        }

        guard object["jsonrpc"] as? String == "2.0" else {
            return false
        }
        if object.keys.contains("result") || object.keys.contains("error") {
            return false
        }
        guard let method = object["method"] as? String, method == "initialize" else {
            return false
        }
        guard let rawID = object["id"], isValidRequestID(rawID) else {
            return false
        }

        return true
    }

    private static func isValidRequestID(_ rawID: Any) -> Bool {
        switch rawID {
        case is NSNull:
            return false
        case is Bool:
            return false
        case is String:
            return true
        case let value as NSNumber:
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return false }
            let doubleValue = value.doubleValue
            return doubleValue.isFinite && doubleValue.rounded() == doubleValue
        case is Int, is Int8, is Int16, is Int32, is Int64:
            return true
        case is UInt, is UInt8, is UInt16, is UInt32, is UInt64:
            return true
        case let value as Double:
            return value.isFinite && value.rounded() == value
        case let value as Float:
            return value.isFinite && value.rounded() == value
        case let value as Decimal:
            return value.isFiniteInteger
        default:
            return false
        }
    }
}

private extension Decimal {
    var isFiniteInteger: Bool {
        var value = self
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        return rounded == self
    }
}
