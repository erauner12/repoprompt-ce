import Foundation
import RepoPromptCore

struct MCPRuntimeRequestContext: @unchecked Sendable {
    let lifetimeClass: MCPToolLifetimeClass
    let routingSnapshot: MCPRuntimeRoutingSnapshot
    let admittedRuntime: WorkspaceAdmittedRuntimeSession
    let adapterTicket: MCPRuntimeAdapterTicket?

    var runtimeID: WorkspaceRuntimeID {
        admittedRuntime.runtimeID
    }

    var sessionID: WorkspaceSessionID {
        admittedRuntime.sessionID
    }

    var admissionToken: WorkspaceRuntimeAdmissionToken {
        admittedRuntime.admissionToken
    }
}

enum MCPRuntimeRequestAdmissionError: Error, Equatable {
    case routingUnavailable
    case mappingChanged
    case adapterUnavailable
    case runtimeUnavailable(WorkspaceRuntimeAdmissionFailure)
}

/// Exactly-once release owner for one admitted MCP runtime request.
actor MCPRuntimeRequestLease {
    let context: MCPRuntimeRequestContext
    private let registry: WorkspaceRuntimeLifecycleRegistry
    private var didRelease = false

    init(context: MCPRuntimeRequestContext, registry: WorkspaceRuntimeLifecycleRegistry) {
        self.context = context
        self.registry = registry
    }

    @discardableResult
    func release() async -> WorkspaceRuntimeReleaseResult? {
        guard !didRelease else { return nil }
        didRelease = true
        return await registry.release(context.admissionToken)
    }
}

enum MCPRuntimeRequestCoordinator {
    static func admit(
        routingSnapshot: MCPRuntimeRoutingSnapshot,
        lifetimeClass: MCPToolLifetimeClass,
        lifecycleRegistry: WorkspaceRuntimeLifecycleRegistry,
        adapterRegistry: MCPAppRuntimeAdapterRegistry
    ) async -> Result<MCPRuntimeRequestLease, MCPRuntimeRequestAdmissionError> {
        if lifetimeClass.requiresUIAdapterAtStart {
            let adapterAvailable = await MainActor.run {
                adapterRegistry.adapter(for: routingSnapshot.ticket) != nil
            }
            guard adapterAvailable else { return .failure(.adapterUnavailable) }
        }

        let admission = await lifecycleRegistry.admit(runtimeID: routingSnapshot.runtimeID)
        guard case let .admitted(admittedRuntime) = admission else {
            if case let .unavailable(failure) = admission {
                return .failure(.runtimeUnavailable(failure))
            }
            return .failure(.routingUnavailable)
        }

        let mappingIsStillExact = await MainActor.run {
            guard let current = adapterRegistry.routingSnapshot(windowID: routingSnapshot.windowID) else {
                return false
            }
            return current.ticket == routingSnapshot.ticket
        }
        guard mappingIsStillExact else {
            _ = await lifecycleRegistry.release(admittedRuntime.admissionToken)
            return .failure(.mappingChanged)
        }

        return .success(MCPRuntimeRequestLease(
            context: MCPRuntimeRequestContext(
                lifetimeClass: lifetimeClass,
                routingSnapshot: routingSnapshot,
                admittedRuntime: admittedRuntime,
                adapterTicket: lifetimeClass.requiresUIAdapterAtStart ? routingSnapshot.ticket : nil
            ),
            registry: lifecycleRegistry
        ))
    }
}
