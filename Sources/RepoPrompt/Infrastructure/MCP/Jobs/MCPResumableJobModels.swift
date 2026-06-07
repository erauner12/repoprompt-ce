import Foundation
import MCP

enum MCPResumableJobStatus: String, Equatable {
    case queued
    case running
    case cancelling
    case completed
    case failed
    case cancelled
    case expired
    case notFound = "not_found"
    case serverRestarted = "server_restarted"

    var isTerminal: Bool {
        switch self {
        case .queued, .running, .cancelling:
            false
        case .completed, .failed, .cancelled, .expired, .notFound, .serverRestarted:
            true
        }
    }
}

struct MCPResumableJobError: Equatable {
    let type: String
    let message: String

    func asObject() -> [String: Value] {
        [
            "type": .string(type),
            "message": .string(message)
        ]
    }
}

struct MCPResumableJobWaitMetadata: Equatable {
    enum Result: String, Equatable {
        case snapshotReady = "snapshot_ready"
        case timedOut = "timed_out"
        case cancelled
        case expired
    }

    let result: Result
    let requestedSeconds: TimeInterval?
    let effectiveSeconds: TimeInterval?

    func asObject() -> [String: Value] {
        var object: [String: Value] = [
            "result": .string(result.rawValue)
        ]
        if let requestedSeconds {
            object["requested_seconds"] = .double(requestedSeconds)
        }
        if let effectiveSeconds {
            object["effective_seconds"] = .double(effectiveSeconds)
        }
        return object
    }
}

struct MCPResumableJobSnapshot: Equatable {
    static let envelopeKind = "mcp_resumable_job"

    let jobID: UUID
    let serverInstanceID: String
    let tool: String
    let windowID: Int?
    let status: MCPResumableJobStatus
    let statusText: String?
    let stage: String?
    let progressMessage: String?
    let createdAt: Date
    let updatedAt: Date
    let expiresAt: Date?
    let pollAfterSeconds: TimeInterval
    let result: Value?
    let error: MCPResumableJobError?
    let wait: MCPResumableJobWaitMetadata?

    var resultAvailable: Bool {
        status == .completed && result != nil
    }

    func expiresInSeconds(now: Date = Date()) -> TimeInterval? {
        guard let expiresAt else { return nil }
        return max(0, expiresAt.timeIntervalSince(now))
    }

    func withWait(_ wait: MCPResumableJobWaitMetadata?) -> MCPResumableJobSnapshot {
        MCPResumableJobSnapshot(
            jobID: jobID,
            serverInstanceID: serverInstanceID,
            tool: tool,
            windowID: windowID,
            status: status,
            statusText: statusText,
            stage: stage,
            progressMessage: progressMessage,
            createdAt: createdAt,
            updatedAt: updatedAt,
            expiresAt: expiresAt,
            pollAfterSeconds: pollAfterSeconds,
            result: result,
            error: error,
            wait: wait
        )
    }

    func asObject(now: Date = Date()) -> [String: Value] {
        var object: [String: Value] = [
            "kind": .string(Self.envelopeKind),
            "job_id": .string(jobID.uuidString),
            "server_instance_id": .string(serverInstanceID),
            "tool": .string(tool),
            "status": .string(status.rawValue),
            "created_at": .string(AgentMCPToolHelpers.timestamp(createdAt)),
            "updated_at": .string(AgentMCPToolHelpers.timestamp(updatedAt)),
            "expires_at": expiresAt.map { .string(AgentMCPToolHelpers.timestamp($0)) } ?? .null,
            "expires_in_seconds": expiresInSeconds(now: now).map { .double($0) } ?? .null,
            "poll_after_seconds": .double(pollAfterSeconds),
            "result_available": .bool(resultAvailable)
        ]
        if let windowID {
            object["window_id"] = .int(windowID)
        }
        if let statusText, !statusText.isEmpty {
            object["status_text"] = .string(statusText)
        }
        if let stage, !stage.isEmpty {
            object["stage"] = .string(stage)
        }
        if let progressMessage, !progressMessage.isEmpty {
            object["progress_message"] = .string(progressMessage)
        }
        if let result, status == .completed {
            object["result"] = result
        }
        if let error {
            object["error"] = .object(error.asObject())
        }
        if let wait {
            object["wait"] = .object(wait.asObject())
        }
        return object
    }

    func toValue(now: Date = Date()) -> Value {
        .object(asObject(now: now))
    }
}
