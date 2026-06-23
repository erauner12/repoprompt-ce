import Foundation

struct CodeMapSelectionGraphRehearsalAdmissionPolicy: Hashable {
    static let initial = Self(
        maximumActiveReservationCount: 1,
        maximumReservedBindingCount: 100_000
    )

    let maximumActiveReservationCount: Int
    let maximumReservedBindingCount: Int

    init(maximumActiveReservationCount: Int, maximumReservedBindingCount: Int) {
        precondition(maximumActiveReservationCount > 0)
        precondition(maximumReservedBindingCount > 0)
        self.maximumActiveReservationCount = maximumActiveReservationCount
        self.maximumReservedBindingCount = maximumReservedBindingCount
    }
}

enum CodeMapSelectionGraphRehearsalAdmissionBusyReason: Hashable {
    case activeReservationCountLimit
    case reservedBindingCountLimit
}

enum CodeMapSelectionGraphRehearsalAdmissionError: Error, Hashable {
    case busy(CodeMapSelectionGraphRehearsalAdmissionBusyReason)
    case accountingOverflow
}

struct CodeMapSelectionGraphRehearsalAdmissionAccounting: Equatable {
    let activeReservationCount: Int
    let reservedBindingCount: Int
    let busyRejectionCount: UInt64
    let hasFailedClosed: Bool
}

final class CodeMapSelectionGraphRehearsalAdmissionPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var reservation: Reservation?

    fileprivate init(
        admission: CodeMapSelectionGraphRehearsalAdmission,
        token: UUID,
        bindingCount: Int
    ) {
        reservation = Reservation(admission: admission, token: token, bindingCount: bindingCount)
    }

    func close() {
        let claimed = lock.withLock {
            defer { reservation = nil }
            return reservation
        }
        if let claimed {
            claimed.admission.release(token: claimed.token, bindingCount: claimed.bindingCount)
        }
    }

    deinit {
        close()
    }

    private struct Reservation {
        let admission: CodeMapSelectionGraphRehearsalAdmission
        let token: UUID
        let bindingCount: Int
    }
}

final class CodeMapSelectionGraphRehearsalAdmission: @unchecked Sendable {
    static let processWide = CodeMapSelectionGraphRehearsalAdmission(policy: .initial)

    private let policy: CodeMapSelectionGraphRehearsalAdmissionPolicy
    private let lock = NSLock()
    private var reservations: [UUID: Int] = [:]
    private var reservedBindingCount = 0
    private var busyRejectionCount: UInt64 = 0
    private var hasFailedClosed = false

    init(policy: CodeMapSelectionGraphRehearsalAdmissionPolicy = .initial) {
        self.policy = policy
    }

    func reserve(bindingCount: Int) throws -> CodeMapSelectionGraphRehearsalAdmissionPermit {
        try lock.withLock {
            guard !hasFailedClosed, bindingCount >= 0 else {
                hasFailedClosed = true
                throw CodeMapSelectionGraphRehearsalAdmissionError.accountingOverflow
            }
            let (nextActiveCount, activeOverflow) = reservations.count.addingReportingOverflow(1)
            let (nextBindingCount, bindingOverflow) = reservedBindingCount.addingReportingOverflow(bindingCount)
            guard !activeOverflow, !bindingOverflow else {
                hasFailedClosed = true
                throw CodeMapSelectionGraphRehearsalAdmissionError.accountingOverflow
            }
            guard nextActiveCount <= policy.maximumActiveReservationCount else {
                incrementBusyRejectionCount()
                throw CodeMapSelectionGraphRehearsalAdmissionError.busy(.activeReservationCountLimit)
            }
            guard nextBindingCount <= policy.maximumReservedBindingCount else {
                incrementBusyRejectionCount()
                throw CodeMapSelectionGraphRehearsalAdmissionError.busy(.reservedBindingCountLimit)
            }

            var token = UUID()
            while reservations[token] != nil {
                token = UUID()
            }
            reservations[token] = bindingCount
            reservedBindingCount = nextBindingCount
            return CodeMapSelectionGraphRehearsalAdmissionPermit(
                admission: self,
                token: token,
                bindingCount: bindingCount
            )
        }
    }

    func accounting() -> CodeMapSelectionGraphRehearsalAdmissionAccounting {
        lock.withLock {
            CodeMapSelectionGraphRehearsalAdmissionAccounting(
                activeReservationCount: reservations.count,
                reservedBindingCount: reservedBindingCount,
                busyRejectionCount: busyRejectionCount,
                hasFailedClosed: hasFailedClosed
            )
        }
    }

    fileprivate func release(token: UUID, bindingCount: Int) {
        lock.withLock {
            guard let recordedCount = reservations[token],
                  recordedCount == bindingCount,
                  recordedCount <= reservedBindingCount
            else {
                hasFailedClosed = true
                return
            }
            reservations.removeValue(forKey: token)
            reservedBindingCount -= recordedCount
        }
    }

    private func incrementBusyRejectionCount() {
        if busyRejectionCount < .max {
            busyRejectionCount += 1
        }
    }
}
