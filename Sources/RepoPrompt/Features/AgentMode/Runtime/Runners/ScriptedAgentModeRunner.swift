import Foundation

#if DEBUG
    @MainActor
    final class ScriptedAgentModeRunner {
        struct Script {
            let token: String

            var interaction: AgentAskUserInteraction {
                AgentAskUserInteraction(
                    title: "Marker",
                    context: "Scripted Director E2E child question.",
                    timeoutSeconds: 600,
                    questions: [
                        AgentAskUserQuestion(
                            id: "marker_choice",
                            question: "Which marker should this child use?",
                            options: [
                                AgentAskUserOption(label: "Alpha"),
                                AgentAskUserOption(label: "Beta")
                            ],
                            allowsMultiple: false,
                            allowsCustom: false
                        )
                    ]
                )
            }
        }

        static let badScriptPrefix = "SCRIPTED_CHILD_BAD_SCRIPT"
        static let completionPrefix = "SCRIPTED_CHILD_V1 answer="

        private let hooks: AgentModeRunService.Hooks
        private let terminalCommitBarrier: AgentRunTerminalCommitBarrier

        init(
            hooks: AgentModeRunService.Hooks,
            terminalCommitBarrier: AgentRunTerminalCommitBarrier
        ) {
            self.hooks = hooks
            self.terminalCommitBarrier = terminalCommitBarrier
        }

        func startRun(
            tabID: UUID,
            session: AgentModeViewModel.TabSession,
            initialUserMessage: String,
            initialMessageForRun: String,
            attachments: [AgentImageAttachment]
        ) async {
            let attachmentReservationID = hooks.reserveAttachmentsForTurn(attachments, session)
            hooks.startNonCodexTurnAccountingIfNeeded(session, initialMessageForRun)

            let runID = AgentModeProcessRunIdentity.startFreshProcessRun(for: session)
            session.activeReasoningItemID = nil
            session.reasoningItemIDsByGroupID.removeAll()
            session.codexReasoningSegmentsByKey.removeAll()

            let ownership = session.beginRunAttempt(source: "scripted")
            let runAttemptID = ownership.attemptID
            session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .preparingRuntime)
            session.runningStatusText = nil
            session.runningStatusSource = nil
            session.runState = .running
            hooks.setAgentRunActive(tabID, true)
            hooks.updateBindings(session)

            session.installRunAttemptTerminalResources(ownership: ownership) { terminalState in
                if session.runID == runID {
                    session.runID = nil
                }
                return {
                    if terminalState != .completed {
                        self.hooks.recordPendingHandoffSendOutcome(session, false)
                    }
                }
            }

            session.agentTask = Task { [weak self, weak session] in
                guard let self, let session else { return }
                await executeScriptedRun(
                    session: session,
                    initialMessageForRun: initialMessageForRun,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    ownership: ownership,
                    attachments: attachments,
                    attachmentReservationID: attachmentReservationID
                )
            }
        }

        private func executeScriptedRun(
            session: AgentModeViewModel.TabSession,
            initialMessageForRun: String,
            runID: UUID,
            runAttemptID: UUID,
            ownership: AgentRunOwnership,
            attachments: [AgentImageAttachment],
            attachmentReservationID: UUID?
        ) async {
            guard session.isCurrentRunAttempt(ownership, expectedRunID: runID) else { return }
            hooks.recordPendingHandoffSendOutcome(session, true)
            hooks.stageConsumedAttachmentFilesForDeferredCleanup(attachments, session)
            hooks.markAttachmentsConsumed(session, attachmentReservationID)

            guard let script = Self.parseScript(from: initialMessageForRun) else {
                await fail(
                    session: session,
                    ownership: ownership,
                    runID: runID,
                    message: "\(Self.badScriptPrefix) missing exact script line",
                    attachmentReservationID: attachmentReservationID
                )
                return
            }

            await Task.yield()
            guard session.runID == runID,
                  session.activeRunAttemptID == runAttemptID
            else { return }
            session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)

            do {
                let response = try await hooks.askUserInteraction(session, script.interaction)
                guard session.isCurrentRunAttempt(ownership, expectedRunID: runID) else { return }
                if response.timedOut || response.skipped {
                    await fail(
                        session: session,
                        ownership: ownership,
                        runID: runID,
                        message: "\(Self.badScriptPrefix) question was not answered",
                        attachmentReservationID: attachmentReservationID
                    )
                    return
                }
                guard let answer = response.answersByQuestionID["marker_choice"]?.answers.first,
                      answer == "Alpha" || answer == "Beta"
                else {
                    await fail(
                        session: session,
                        ownership: ownership,
                        runID: runID,
                        message: "\(Self.badScriptPrefix) invalid answer",
                        attachmentReservationID: attachmentReservationID
                    )
                    return
                }
                await Task.yield()
                guard session.isCurrentRunAttempt(ownership, expectedRunID: runID) else { return }
                session.runState = .running
                let completion = "\(Self.completionPrefix)\(answer) token=\(script.token)"
                session.appendItem(AgentChatItem.assistant(completion, sequenceIndex: session.nextSequenceIndex))
                hooks.updateBindings(session)

                await terminalCommitBarrier.commit(.init(
                    session: session,
                    ownership: ownership,
                    expectedRunID: runID,
                    terminalState: .completed,
                    source: "scripted.completed",
                    attachmentReservationID: attachmentReservationID,
                    attachmentDisposition: .deleteFiles,
                    finalizeNonCodexUsage: true,
                    supportsFollowUp: false,
                    notifyTurnComplete: true,
                    prepareProviderState: {
                        session.runID = nil
                        return nil
                    }
                ))
            } catch is CancellationError {
                await terminalCommitBarrier.commit(.init(
                    session: session,
                    ownership: ownership,
                    expectedRunID: runID,
                    terminalState: .cancelled,
                    source: "scripted.cancelled",
                    attachmentReservationID: attachmentReservationID,
                    attachmentDisposition: .deleteFiles,
                    finalizeNonCodexUsage: true,
                    supportsFollowUp: false,
                    notifyTurnComplete: false,
                    prepareProviderState: {
                        session.runID = nil
                        return nil
                    }
                ))
            } catch {
                await fail(
                    session: session,
                    ownership: ownership,
                    runID: runID,
                    message: "\(Self.badScriptPrefix) \(error.localizedDescription)",
                    attachmentReservationID: attachmentReservationID
                )
            }
        }

        private func fail(
            session: AgentModeViewModel.TabSession,
            ownership: AgentRunOwnership,
            runID: UUID,
            message: String,
            attachmentReservationID: UUID?
        ) async {
            await terminalCommitBarrier.commit(.init(
                session: session,
                ownership: ownership,
                expectedRunID: runID,
                terminalState: .failed,
                source: "scripted.failed",
                errorText: message,
                attachmentReservationID: attachmentReservationID,
                attachmentDisposition: .deleteFiles,
                finalizeNonCodexUsage: true,
                supportsFollowUp: false,
                notifyTurnComplete: false,
                prepareProviderState: {
                    session.runID = nil
                    return nil
                }
            ))
        }

        static func parseScript(from text: String) -> Script? {
            text
                .components(separatedBy: .newlines)
                .lazy
                .compactMap(parseScriptLine(_:))
                .first
        }

        private static func parseScriptLine(_ line: String) -> Script? {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "SCRIPTED_CHILD_V1 ask_marker token="
            let suffix = " options=Alpha,Beta"
            guard trimmed.hasPrefix(prefix),
                  trimmed.hasSuffix(suffix)
            else { return nil }
            let tokenStart = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            let tokenEnd = trimmed.index(trimmed.endIndex, offsetBy: -suffix.count)
            guard tokenStart < tokenEnd else { return nil }
            let token = String(trimmed[tokenStart ..< tokenEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty,
                  token.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
            else { return nil }
            return Script(token: token)
        }
    }
#endif
