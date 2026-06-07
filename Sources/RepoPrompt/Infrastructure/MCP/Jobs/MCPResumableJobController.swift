import Foundation
import MCP

/// Shared argument parser and lifecycle helper for opt-in resumable MCP tools.
///
/// Tools keep their omitted-`op` synchronous behavior outside this controller. When a
/// provider sees an explicit resumable `op`, this helper centralizes validation,
/// control-operation argument restrictions, wait timeout clamping, and store calls.
struct MCPResumableJobController {
    enum Operation: String, Equatable {
        case start
        case poll
        case wait
        case cancel
    }

    struct Configuration: Equatable {
        /// Default blocking wait when `op=wait` omits `timeout`.
        var defaultWaitTimeoutSeconds: TimeInterval = 25
        /// HTTP-friendly cap applied to every `op=wait` timeout.
        var maximumWaitTimeoutSeconds: TimeInterval = 25
        /// Routing/control fields allowed on poll/wait/cancel in addition to common job fields.
        var routingArgumentKeys: Set<String> = ["_rawJSON", "_tabID", "_windowID", "context_id", "window_id"]
    }

    struct Request: Equatable {
        let operation: Operation?
        let jobID: UUID?
        let requestedTimeoutSeconds: TimeInterval?
        let effectiveTimeoutSeconds: TimeInterval?
        let serverInstanceID: String?
        let clientRequestID: String?

        var isSynchronous: Bool {
            operation == nil
        }
    }

    let tool: String
    let windowID: Int?
    let businessArgumentKeys: Set<String>
    let store: MCPResumableJobStore
    var configuration: Configuration

    init(
        tool: String,
        windowID: Int?,
        businessArgumentKeys: Set<String>,
        store: MCPResumableJobStore = .shared,
        configuration: Configuration = Configuration()
    ) {
        self.tool = tool
        self.windowID = windowID
        self.businessArgumentKeys = businessArgumentKeys
        self.store = store
        self.configuration = configuration
    }

    func parseRequest(args: [String: Value]) throws -> Request {
        guard let operation = try parseOperation(args["op"]) else {
            return Request(
                operation: nil,
                jobID: nil,
                requestedTimeoutSeconds: nil,
                effectiveTimeoutSeconds: nil,
                serverInstanceID: nil,
                clientRequestID: nil
            )
        }

        switch operation {
        case .start:
            if AgentMCPToolHelpers.normalizedString(args["job_id"]) != nil {
                throw MCPError.invalidParams("\(tool) op=start creates a new resumable job and does not accept job_id.")
            }
            if args["timeout"] != nil {
                throw MCPError.invalidParams("\(tool) op=start does not accept timeout; timeout is only supported with op=wait.")
            }
            return Request(
                operation: operation,
                jobID: nil,
                requestedTimeoutSeconds: nil,
                effectiveTimeoutSeconds: nil,
                serverInstanceID: AgentMCPToolHelpers.normalizedString(args["server_instance_id"]),
                clientRequestID: AgentMCPToolHelpers.normalizedString(args["client_request_id"])
            )

        case .poll, .wait, .cancel:
            try validateControlArguments(args: args, operation: operation)
            let jobID = try parseJobID(args["job_id"], operation: operation)
            let requestedTimeoutSeconds: TimeInterval?
            let effectiveTimeoutSeconds: TimeInterval?
            if operation == .wait {
                requestedTimeoutSeconds = try AgentMCPToolHelpers.parseTimeoutSeconds(args["timeout"])
                effectiveTimeoutSeconds = effectiveWaitTimeoutSeconds(requested: requestedTimeoutSeconds)
            } else {
                requestedTimeoutSeconds = nil
                effectiveTimeoutSeconds = nil
            }
            return Request(
                operation: operation,
                jobID: jobID,
                requestedTimeoutSeconds: requestedTimeoutSeconds,
                effectiveTimeoutSeconds: effectiveTimeoutSeconds,
                serverInstanceID: AgentMCPToolHelpers.normalizedString(args["server_instance_id"]),
                clientRequestID: nil
            )
        }
    }

    func start(
        args: [String: Value],
        statusText: String? = nil,
        stage: String? = nil,
        progressMessage: String? = nil,
        pollAfterSeconds: TimeInterval? = nil,
        worker: @escaping @Sendable (_ jobID: UUID) async -> Void
    ) async throws -> MCPResumableJobSnapshot {
        let request = try parseRequest(args: args)
        guard request.operation == .start else {
            throw MCPError.invalidParams("\(tool) start helper requires op=start.")
        }

        let registration = await store.register(
            tool: tool,
            windowID: windowID,
            clientRequestID: request.clientRequestID,
            statusText: statusText,
            stage: stage,
            progressMessage: progressMessage,
            pollAfterSeconds: pollAfterSeconds
        )
        guard !registration.reusedExistingJob else {
            return registration.snapshot
        }

        let jobID = registration.jobID
        let task = Task<Void, Never> {
            await worker(jobID)
        }
        return await store.attachWorkerTask(
            jobID: jobID,
            tool: tool,
            windowID: windowID,
            task: task
        )
    }

    func poll(args: [String: Value]) async throws -> MCPResumableJobSnapshot {
        let request = try parseRequest(args: args)
        guard request.operation == .poll, let jobID = request.jobID else {
            throw MCPError.invalidParams("\(tool) poll helper requires op=poll and job_id.")
        }
        return await store.poll(
            jobID: jobID,
            tool: tool,
            windowID: windowID,
            serverInstanceID: request.serverInstanceID
        )
    }

    func wait(args: [String: Value]) async throws -> MCPResumableJobSnapshot {
        let request = try parseRequest(args: args)
        guard request.operation == .wait, let jobID = request.jobID else {
            throw MCPError.invalidParams("\(tool) wait helper requires op=wait and job_id.")
        }
        return await store.wait(
            jobID: jobID,
            tool: tool,
            windowID: windowID,
            requestedTimeoutSeconds: request.requestedTimeoutSeconds,
            effectiveTimeoutSeconds: request.effectiveTimeoutSeconds,
            serverInstanceID: request.serverInstanceID
        )
    }

    func cancel(args: [String: Value], statusText: String? = "Cancellation requested.") async throws -> MCPResumableJobSnapshot {
        let request = try parseRequest(args: args)
        guard request.operation == .cancel, let jobID = request.jobID else {
            throw MCPError.invalidParams("\(tool) cancel helper requires op=cancel and job_id.")
        }
        return await store.cancel(
            jobID: jobID,
            tool: tool,
            windowID: windowID,
            statusText: statusText,
            serverInstanceID: request.serverInstanceID
        )
    }

    func handleControl(args: [String: Value]) async throws -> MCPResumableJobSnapshot {
        let request = try parseRequest(args: args)
        switch request.operation {
        case .poll:
            return try await poll(args: args)
        case .wait:
            return try await wait(args: args)
        case .cancel:
            return try await cancel(args: args)
        case .start:
            throw MCPError.invalidParams("\(tool) handleControl does not start jobs. Use start(args:worker:) for op=start.")
        case nil:
            throw MCPError.invalidParams("\(tool) resumable control op is required.")
        }
    }

    private func parseOperation(_ value: Value?) throws -> Operation? {
        guard let raw = AgentMCPToolHelpers.normalizedString(value)?.lowercased() else { return nil }
        guard let operation = Operation(rawValue: raw) else {
            throw MCPError.invalidParams("Unsupported \(tool) op '\(raw)'. Use start, poll, wait, or cancel.")
        }
        return operation
    }

    private func parseJobID(_ value: Value?, operation: Operation) throws -> UUID {
        guard let raw = AgentMCPToolHelpers.normalizedString(value) else {
            throw MCPError.invalidParams("job_id is required for \(tool) op=\(operation.rawValue).")
        }
        guard let uuid = UUID(uuidString: raw) else {
            throw MCPError.invalidParams("job_id must be a valid UUID for \(tool) op=\(operation.rawValue).")
        }
        return uuid
    }

    private func validateControlArguments(args: [String: Value], operation: Operation) throws {
        let allowed = controlAllowedArgumentKeys(operation: operation)
        let unsupported = args.keys
            .filter { !allowed.contains($0) }
            .sorted()
        guard unsupported.isEmpty else {
            let business = unsupported.filter { businessArgumentKeys.contains($0) }
            if !business.isEmpty {
                throw MCPError.invalidParams(
                    "\(tool) op=\(operation.rawValue) does not accept business arguments: \(business.joined(separator: ", ")). Start a new job to change tool input."
                )
            }
            throw MCPError.invalidParams(
                "\(tool) op=\(operation.rawValue) does not support arguments: \(unsupported.joined(separator: ", ")). Supported fields: \(allowed.sorted().joined(separator: ", "))."
            )
        }
    }

    private func controlAllowedArgumentKeys(operation: Operation) -> Set<String> {
        var allowed = configuration.routingArgumentKeys
        allowed.formUnion(["op", "job_id", "server_instance_id"])
        if operation == .wait {
            allowed.insert("timeout")
        }
        return allowed
    }

    private func effectiveWaitTimeoutSeconds(requested: TimeInterval?) -> TimeInterval {
        let fallback = max(0, configuration.defaultWaitTimeoutSeconds)
        let cap = max(0, configuration.maximumWaitTimeoutSeconds)
        let requestedOrDefault = requested ?? fallback
        return min(requestedOrDefault, cap)
    }
}
