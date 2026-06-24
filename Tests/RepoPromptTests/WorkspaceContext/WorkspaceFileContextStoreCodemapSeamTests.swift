import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class WorkspaceFileContextStoreCodemapSeamTests: XCTestCase {
    func testRootLoadSearchAndReadDoNotInvokeCodemapRuntimeProvider() async throws {
        let sandbox = try CodemapStoreFixture.makeSandbox(name: #function)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.write("struct Feature {}\n", to: root.appendingPathComponent("Sources/Feature.swift"))

        let providerInvocations = CodemapLockedCounter()
        let graphProbe = CodemapSelectionGraphProbe()
        let store = WorkspaceFileContextStore(
            codemapRuntimeProvider: {
                providerInvocations.increment()
                throw WorkspaceCodemapBindingEngineProviderError.unconfigured
            },
            selectionGraphFactory: graphProbe.factory
        )

        let loaded = try await store.loadRoot(path: root.path)
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let search = WorkspaceSearchService()
        _ = await search.rebuildIndex(from: snapshot)
        let searchResult = await search.search("Feature", limit: 10)
        let content = try await store.readContent(
            rootID: loaded.id,
            relativePath: "Sources/Feature.swift"
        )

        XCTAssertEqual(snapshot.files.map(\.standardizedRelativePath), ["Sources/Feature.swift"])
        XCTAssertEqual(searchResult.results.map(\.standardizedRelativePath), ["Sources/Feature.swift"])
        XCTAssertEqual(content, "struct Feature {}\n")
        XCTAssertEqual(providerInvocations.value, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)
        await store.unloadRoot(id: loaded.id)
        XCTAssertEqual(providerInvocations.value, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)
    }

    func testFirstExplicitDemandReturnsStableExactRootPendingTicketAndRegistersOnce() async throws {
        let gate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(name: #function, resolutionGate: gate)
        addTeardownBlock {
            await gate.release()
            await fixture.shutdown()
        }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)

        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let duplicateTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        XCTAssertNotEqual(firstTicket.retainID, duplicateTicket.retainID)
        XCTAssertEqual(firstTicket.requestID, duplicateTicket.requestID)
        XCTAssertEqual(firstTicket.rootEpoch, duplicateTicket.rootEpoch)
        XCTAssertEqual(firstTicket.fileID, duplicateTicket.fileID)
        XCTAssertEqual(firstTicket.requestGeneration, duplicateTicket.requestGeneration)
        let gateEntered = await gate.waitUntilEntered()
        XCTAssertTrue(gateEntered)

        let candidate = await fixture.registry.makeBindingCatalogClient()
            .resolveManifestBinding(firstTicket.rootEpoch, file.standardizedRelativePath)
        XCTAssertEqual(candidate?.identity.fileID, file.id)
        XCTAssertEqual(candidate?.identity.rootID, loaded.id)
        XCTAssertEqual(candidate?.identity.rootLifetimeID, firstTicket.rootEpoch.rootLifetimeID)
        XCTAssertEqual(fixture.providerAccessCount.value, 1)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 1)
        XCTAssertEqual(fixture.engineFactoryCount.value, 1)
        let resolutionCount = await gate.resolutionCount
        XCTAssertEqual(resolutionCount, 1)

        await gate.release()
        let settled = try await settledResult(store: store, ticket: firstTicket)
        assertNonGitTerminal(settled)
        await store.unloadRoot(id: loaded.id)
    }

    func testFrozenPresentationBundleRetainsReadyHandleLeaseAcrossAwaitAndRendersLogicalPaths() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Alpha.swift": """
                protocol AlphaProtocol {
                    func alpha() -> String
                }

                struct Alpha: AlphaProtocol {
                    func alpha() -> String { "alpha" }
                }
                """,
                "Sources/Zeta.swift": """
                protocol ZetaProtocol {
                    func zeta() -> String
                }

                struct Zeta: ZetaProtocol {
                    func zeta() -> String { "zeta" }
                }
                """
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let suspensionGate = CodemapSuspensionGate()
        addTeardownBlock {
            await suspensionGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let alpha = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Alpha.swift"
        })
        let zeta = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Zeta.swift"
        })
        let alphaTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: alpha.id)
        )
        let alphaReady = try await readyResult(
            settledResult(store: store, ticket: alphaTicket)
        )
        let zetaTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: zeta.id)
        )
        let zetaReady = try await readyResult(
            settledResult(store: store, ticket: zetaTicket)
        )
        XCTAssertNil(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: root.path,
            standardizedRelativePath: alpha.standardizedRelativePath
        ))
        XCTAssertNil(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Logical Workspace",
            standardizedRelativePath: alpha.standardizedFullPath
        ))
        let alphaPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Logical Workspace",
            standardizedRelativePath: alpha.standardizedRelativePath
        ))
        let zetaPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Logical Workspace",
            standardizedRelativePath: zeta.standardizedRelativePath
        ))
        let engine = try fixture.runtime().bindingEngine()
        let accountingBeforeFreeze = await engine.accounting()

        var callerBundle: WorkspaceCodemapFrozenPresentationBundle? = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: zetaTicket, logicalPath: zetaPath),
                WorkspaceCodemapPresentationRequest(ticket: alphaTicket, logicalPath: alphaPath)
            ])
        )
        do {
            let bundle = try XCTUnwrap(callerBundle)
            XCTAssertEqual(bundle.rootEpoch, alphaTicket.rootEpoch)
            XCTAssertEqual(
                bundle.entries.map(\.logicalPath.displayPath),
                ["Logical Workspace/Sources/Alpha.swift", "Logical Workspace/Sources/Zeta.swift"]
            )
            XCTAssertEqual(
                bundle.entries.map(\.artifactKey),
                [alphaReady.snapshot.artifactKey, zetaReady.snapshot.artifactKey]
            )
            XCTAssertEqual(
                bundle.entries.map(\.artifactKey.pipelineIdentity),
                [
                    alphaReady.snapshot.artifactKey.pipelineIdentity,
                    zetaReady.snapshot.artifactKey.pipelineIdentity
                ]
            )

            let rendered = try await renderedPresentationEntries(
                store.renderCodemapPresentation(bundle)
            )
            XCTAssertEqual(
                rendered.map(\.logicalPath.displayPath),
                ["Logical Workspace/Sources/Alpha.swift", "Logical Workspace/Sources/Zeta.swift"]
            )
            XCTAssertTrue(rendered[0].text.contains("File: Logical Workspace/Sources/Alpha.swift"))
            XCTAssertTrue(rendered[1].text.contains("File: Logical Workspace/Sources/Zeta.swift"))
            XCTAssertFalse(rendered.contains { $0.text.contains(root.path) })
            XCTAssertTrue(rendered.allSatisfy { $0.tokenCount > 0 })

            let accountingAfterRender = await engine.accounting()
            XCTAssertEqual(
                accountingAfterRender.counters.validatedWorktreeReads,
                accountingBeforeFreeze.counters.validatedWorktreeReads
            )
            XCTAssertEqual(accountingAfterRender.counters.builds, accountingBeforeFreeze.counters.builds)
            XCTAssertEqual(
                accountingAfterRender.counters.manifestLoads,
                accountingBeforeFreeze.counters.manifestLoads
            )
            XCTAssertEqual(fixture.buildCount.value, 2)
        }

        var suspendedRenderTask: Task<WorkspaceCodemapPresentationRenderDisposition, Never>?
        if let bundle = callerBundle {
            suspendedRenderTask = Task { [bundle] in
                await suspensionGate.enterAndWait()
                return await store.renderCodemapPresentation(bundle)
            }
        }
        let suspensionEntered = await suspensionGate.waitUntilEntered()
        XCTAssertTrue(suspensionEntered)
        if let bundle = callerBundle {
            let bundleReleased = await store.releaseCodemapPresentation(bundle)
            XCTAssertTrue(bundleReleased)
        } else {
            XCTFail("The caller bundle must remain alive until its gated owner captures it.")
        }
        callerBundle = nil

        await store.unloadRoot(id: loaded.id)
        let runtime = try fixture.runtime()
        let callerRetainedAccounting = await runtime.artifactStore.accounting()
        XCTAssertEqual(callerRetainedAccounting.activeLeaseCount, 2)
        XCTAssertGreaterThan(callerRetainedAccounting.activeLeaseBytes, 0)

        await suspensionGate.release()
        let suspendedRender = await suspendedRenderTask?.value
        if let suspendedRender {
            assertPresentationRenderUnavailable(suspendedRender, equals: .bundleNotRetained)
        } else {
            XCTFail("The suspended caller render task must exist.")
        }
        suspendedRenderTask = nil

        let fullyReleasedAccounting = await runtime.artifactStore.accounting()
        XCTAssertEqual(fullyReleasedAccounting.activeLeaseCount, 0)
        XCTAssertEqual(fullyReleasedAccounting.activeLeaseBytes, 0)
    }

    func testOperationPresentationCoordinatesMultiRootLogicalOutputAndReleasesAllRetains() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let firstRoot = try repositoryFixture.makeRepository(
            named: "physical-first-secret",
            files: ["Sources/First.swift": "protocol FirstProtocol { func first() -> String }\nstruct First: FirstProtocol { func first() -> String { \"first\" } }\n"]
        )
        let secondRoot = try repositoryFixture.makeRepository(
            named: "physical-second-secret",
            files: ["Sources/Second.swift": "protocol SecondProtocol { func second() -> String }\nstruct Second: SecondProtocol { func second() -> String { \"second\" } }\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let firstLoaded = try await store.loadRoot(path: firstRoot.path)
        let secondLoaded = try await store.loadRoot(path: secondRoot.path)
        let firstFiles = await store.files(inRoot: firstLoaded.id)
        let firstFile = try XCTUnwrap(firstFiles.first)
        let secondFiles = await store.files(inRoot: secondLoaded.id)
        let secondFile = try XCTUnwrap(secondFiles.first)

        let presentation = try await WorkspaceCodemapPresentationCoordinator(store: store)
            .presentation(
                for: .exact(fileIDs: [secondFile.id, firstFile.id], completeRootSet: false),
                rootScope: .allLoaded,
                logicalRootDisplayNamesByRootID: [
                    firstLoaded.id: "LogicalFirst",
                    secondLoaded.id: "LogicalSecond"
                ]
            )

        XCTAssertEqual(presentation.coverage, .complete)
        XCTAssertEqual(presentation.orderedEntries.count, 2)
        XCTAssertEqual(Set(presentation.orderedEntries.map(\.rootEpoch)).count, 2)
        XCTAssertEqual(
            presentation.orderedEntries.map(\.logicalPath.displayPath),
            ["LogicalFirst/Sources/First.swift", "LogicalSecond/Sources/Second.swift"]
        )
        XCTAssertTrue(presentation.orderedEntries.allSatisfy { $0.tokenCount == TokenCalculationService.estimateTokens(for: $0.text) })
        XCTAssertFalse(presentation.orderedEntries.contains { $0.text.contains(firstRoot.path) || $0.text.contains(secondRoot.path) })
        let receipt = try XCTUnwrap(presentation.publicationReceipt)
        for ticket in receipt.demandTickets {
            let retainCount = await store.codemapArtifactDemandRetainCountForTesting(ticket)
            XCTAssertEqual(retainCount, 0)
        }
        for bundle in receipt.bundles {
            let retainCount = await store.codemapPresentationRetainCountForTesting(
                rootEpoch: bundle.rootEpoch
            )
            XCTAssertEqual(retainCount, 0)
        }
    }

    func testOperationPresentationMixedReadyAndPendingPublishesReadyReceipt() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Ready.swift": "struct Ready { func value() -> Int { 1 } }\n",
                "Sources/Pending.swift": "struct Pending { func value() -> Int { 2 } }\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let pendingFileID = CodemapLockedValues<UUID>()
        let store = fixture.makeStore(demandResultHook: { ticket, result in
            if pendingFileID.values.contains(ticket.fileID) {
                return .busy(retryAfterMilliseconds: 1000)
            }
            return result
        })
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let ready = try XCTUnwrap(files.first { $0.name == "Ready.swift" })
        let pending = try XCTUnwrap(files.first { $0.name == "Pending.swift" })
        pendingFileID.append(pending.id)
        let warmResult = await store.requestCodemapArtifact(forFileID: ready.id)
        let warmReady: WorkspaceCodemapArtifactDemandReady
        switch warmResult {
        case let .ready(value):
            warmReady = value
        case let .pending(ticket):
            warmReady = try await readyResult(
                settledResult(store: store, ticket: ticket)
            )
        case let .unavailable(reason):
            XCTFail("Expected ready warm demand, got \(reason)")
            throw CodemapStoreTestError.timedOut
        }
        let receipts = CodemapLockedValues<WorkspaceCodemapOperationPresentationPublicationReceipt>()
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: WorkspaceCodemapPresentationRequestPolicy(
                maximumReadinessRounds: 1,
                maximumTotalWait: .milliseconds(50)
            ),
            beforePublicationRevalidation: { receipts.append($0) }
        )

        let presentation = try await coordinator.presentation(
            for: .exact(fileIDs: [pending.id, ready.id], completeRootSet: false),
            rootScope: .allLoaded
        )

        guard case .partial = presentation.coverage else {
            return XCTFail("A ready sibling must remain publishable while another demand is pending")
        }
        XCTAssertEqual(presentation.orderedEntries.map(\.fileID), [ready.id])
        let receipt = try XCTUnwrap(receipts.values.first)
        XCTAssertEqual(receipt.candidates.map(\.fileID), [ready.id])
        XCTAssertEqual(receipt.demandTickets.map(\.fileID), [ready.id])
        XCTAssertTrue(receipt.bundles.allSatisfy { bundle in
            bundle.entries.allSatisfy { $0.ticket.fileID == ready.id }
        })
        _ = await store.cancelCodemapArtifactDemand(warmReady.ticket)
    }

    func testStructureSeedDemandLimitRejectsBeforeRuntimeOrBuild() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/One.swift": "struct One {}\n",
                "Sources/Two.swift": "struct Two {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        XCTAssertEqual(files.count, 2)
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: WorkspaceCodemapPresentationRequestPolicy(
                maximumCandidateDemandCount: 1
            )
        )

        let presentation = try await coordinator.structurePresentation(
            seedFileIDs: files.map(\.id),
            direction: nil,
            traversalLimits: .init(
                maximumDepth: 0,
                maximumNodeCount: 10,
                maximumEdgeCount: 10,
                maximumByteCount: 4096
            ),
            outputLimits: .init(maximumFileCount: 10, maximumCodemapTokenCount: 6000),
            rootScope: .allLoaded
        )

        XCTAssertEqual(presentation.outcome, .budget)
        XCTAssertTrue(presentation.entries.isEmpty)
        XCTAssertEqual(presentation.resolvedSeedCount, 0)
        XCTAssertTrue(presentation.issues.contains {
            if case .seedDemandLimit(attempted: 2, limit: 1) = $0 { return true }
            return false
        })
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 0)
        XCTAssertEqual(fixture.engineFactoryCount.value, 0)
        XCTAssertEqual(fixture.manifestReadCount.value, 0)
        XCTAssertEqual(fixture.buildCount.value, 0)
    }

    func testStructurePresentationSeedUsesPairedCodemapRenderAndReleasesReceiptResources() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "physical-secret",
            files: [
                "Sources/Feature.swift": "protocol FeatureProtocol { func feature() }\nstruct Feature: FeatureProtocol { func feature() {} }\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let releasedTickets = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        let store = fixture.makeStore(cancellationCleanupHook: { ticket in
            releasedTickets.append(ticket)
        })
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)

        let presentation = try await WorkspaceCodemapPresentationCoordinator(store: store)
            .structurePresentation(
                seedFileIDs: [file.id],
                direction: nil,
                traversalLimits: .init(
                    maximumDepth: 0,
                    maximumNodeCount: 10,
                    maximumEdgeCount: 10,
                    maximumByteCount: 4096
                ),
                outputLimits: .init(
                    maximumFileCount: 10,
                    maximumCodemapTokenCount: 6000
                ),
                rootScope: .allLoaded,
                logicalRootDisplayNamesByRootID: [loaded.id: "Logical"]
            )

        XCTAssertEqual(presentation.outcome, .ready)
        let rendered = try XCTUnwrap(presentation.entries.first)
        XCTAssertTrue(rendered.isSeed)
        XCTAssertEqual(rendered.depth, 0)
        XCTAssertEqual(rendered.entry.logicalPath.displayPath, "Logical/Sources/Feature.swift")
        XCTAssertEqual(rendered.entry.tokenCount, TokenCalculationService.estimateTokens(for: rendered.entry.text))
        XCTAssertFalse(rendered.entry.text.contains(root.path))
        let ticket = try XCTUnwrap(releasedTickets.values.last)
        let demandRetainCount = await store.codemapArtifactDemandRetainCountForTesting(ticket)
        let presentationRetainCount = await store.codemapPresentationRetainCountForTesting(
            rootEpoch: ticket.rootEpoch
        )
        XCTAssertEqual(demandRetainCount, 0)
        XCTAssertEqual(presentationRetainCount, 0)
    }

    func testStructurePublicationRevocationRetriesThenReturnsTypedStale() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Feature.swift": "protocol FeatureProtocol { func feature() }\nstruct Feature: FeatureProtocol { func feature() {} }\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let publicationCount = CodemapLockedCounter()
        let structureAttempts = CodemapLockedValues<Int>()
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: WorkspaceCodemapPresentationRequestPolicy(
                maximumReadinessRounds: 20,
                maximumTotalWait: .seconds(10)
            ),
            beforePublicationRevalidation: { _ in
                publicationCount.increment()
                if publicationCount.value == 1 {
                    await store.unloadRoot(id: loaded.id)
                }
            },
            structureAttemptDidBegin: { structureAttempts.append($0) }
        )

        let presentation = try await coordinator.structurePresentation(
            seedFileIDs: [file.id],
            direction: nil,
            traversalLimits: .init(
                maximumDepth: 0,
                maximumNodeCount: 10,
                maximumEdgeCount: 10,
                maximumByteCount: 4096
            ),
            outputLimits: .init(maximumFileCount: 10, maximumCodemapTokenCount: 6000),
            rootScope: .allLoaded
        )

        XCTAssertEqual(
            presentation.outcome,
            .stale,
            "issues=\(presentation.issues), publications=\(publicationCount.value)"
        )
        XCTAssertTrue(presentation.entries.isEmpty)
        XCTAssertEqual(structureAttempts.values, [0, 1])
        XCTAssertEqual(publicationCount.value, 1)
        XCTAssertTrue(presentation.issues.contains {
            if case .publicationStale = $0 { return true }
            return false
        })
    }

    func testOperationPresentationRevocationBeforePublicationRetriesAndReturnsIncomplete() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "protocol FeatureProtocol { func feature() -> String }\nstruct Feature: FeatureProtocol { func feature() -> String { \"feature\" } }\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let receipts = CodemapLockedValues<WorkspaceCodemapOperationPresentationPublicationReceipt>()
        let publicationCount = CodemapLockedCounter()
        let operationCount = CodemapLockedCounter()
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            beforePublicationRevalidation: { receipt in
                receipts.append(receipt)
                publicationCount.increment()
                if publicationCount.value == 1 {
                    await store.unloadRoot(id: loaded.id)
                }
            }
        )

        let presentation = try await coordinator.withPresentation(
            for: .exact(fileIDs: [file.id], completeRootSet: false),
            rootScope: .allLoaded
        ) { presentation in
            operationCount.increment()
            return presentation
        }

        XCTAssertTrue(presentation.orderedEntries.isEmpty)
        guard case .unavailable = presentation.coverage else {
            return XCTFail("Revoked publication must return typed incomplete coverage")
        }
        XCTAssertEqual(publicationCount.value, 1)
        XCTAssertEqual(operationCount.value, 2)
        let firstReceipt = try XCTUnwrap(receipts.values.first)
        for ticket in firstReceipt.demandTickets {
            let retainCount = await store.codemapArtifactDemandRetainCountForTesting(ticket)
            XCTAssertEqual(retainCount, 0)
        }
        for bundle in firstReceipt.bundles {
            let retainCount = await store.codemapPresentationRetainCountForTesting(
                rootEpoch: bundle.rootEpoch
            )
            XCTAssertEqual(retainCount, 0)
        }
    }

    func testOperationPresentationCancellationDuringPendingWaitReleasesOwnedDemandOnce() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let resolutionGate = CodemapResolutionGate()
        let waiterGate = CodemapSuspensionGate()
        let fixture = try CodemapStoreFixture(name: #function, resolutionGate: resolutionGate)
        addTeardownBlock {
            await waiterGate.release()
            await resolutionGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let cancelledTickets = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        let store = fixture.makeStore(cancellationCleanupHook: { ticket in
            cancelledTickets.append(ticket)
        })
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            waiter: WorkspaceCodemapPresentationWaiter { _ in
                await waiterGate.enterAndWait()
                try Task.checkCancellation()
            }
        )
        let task = Task {
            try await coordinator.presentation(
                for: .exact(fileIDs: [file.id], completeRootSet: false),
                rootScope: .allLoaded
            )
        }

        let waiterEntered = await waiterGate.waitUntilEntered()
        XCTAssertTrue(waiterEntered)
        task.cancel()
        await waiterGate.release()
        await resolutionGate.release()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let cancelledTicket = try XCTUnwrap(cancelledTickets.values.first)
        XCTAssertEqual(cancelledTickets.values.count, 1)
        let retainCount = await store.codemapArtifactDemandRetainCountForTesting(cancelledTicket)
        XCTAssertEqual(retainCount, 0)
        let presentationRetainCount = await store.codemapPresentationRetainCountForTesting(
            rootEpoch: cancelledTicket.rootEpoch
        )
        XCTAssertEqual(presentationRetainCount, 0)
    }

    func testScopedOperationCancellationAfterRenderReleasesDemandAndPresentationOnce() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct ScopedCancellationFeature { func renderable() {} }\n"]
        )
        let operationGate = CodemapSuspensionGate()
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await operationGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let cancelledTickets = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        let store = fixture.makeStore(cancellationCleanupHook: { ticket in
            cancelledTickets.append(ticket)
        })
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let coordinator = WorkspaceCodemapPresentationCoordinator(store: store)
        let task = Task {
            try await coordinator.withPresentation(
                for: .exact(fileIDs: [file.id], completeRootSet: false),
                rootScope: .allLoaded
            ) { presentation in
                XCTAssertEqual(presentation.orderedEntries.count, 1)
                await operationGate.enterAndWait()
                try Task.checkCancellation()
                return presentation
            }
        }

        let operationEntered = await operationGate.waitUntilEntered()
        XCTAssertTrue(operationEntered)
        task.cancel()
        await operationGate.release()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let ticket = try XCTUnwrap(cancelledTickets.values.first)
        XCTAssertEqual(cancelledTickets.values.count, 1)
        let demandRetainCount = await store.codemapArtifactDemandRetainCountForTesting(ticket)
        let presentationRetainCount = await store.codemapPresentationRetainCountForTesting(
            rootEpoch: ticket.rootEpoch
        )
        XCTAssertEqual(demandRetainCount, 0)
        XCTAssertEqual(presentationRetainCount, 0)
    }

    func testOperationPresentationPendingIsTypedAndReleasedWithoutFallback() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let resolutionGate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(name: #function, resolutionGate: resolutionGate)
        addTeardownBlock {
            await resolutionGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: WorkspaceCodemapPresentationRequestPolicy(
                maximumReadinessRounds: 1,
                maximumTotalWait: .milliseconds(50)
            )
        )

        let presentation = try await coordinator.presentation(
            for: .exact(fileIDs: [file.id], completeRootSet: false),
            rootScope: .allLoaded
        )

        guard case let .pending(issues) = presentation.coverage else {
            return XCTFail("Expected typed pending coverage")
        }
        let ticket = try XCTUnwrap(issues.compactMap { issue -> WorkspaceCodemapArtifactDemandTicket? in
            if case let .pending(_, ticket) = issue { return ticket }
            return nil
        }.first)
        XCTAssertTrue(presentation.orderedEntries.isEmpty)
        XCTAssertNil(presentation.publicationReceipt)
        let retainCount = await store.codemapArtifactDemandRetainCountForTesting(ticket)
        XCTAssertEqual(retainCount, 0)
        let presentationRetainCount = await store.codemapPresentationRetainCountForTesting(
            rootEpoch: ticket.rootEpoch
        )
        XCTAssertEqual(presentationRetainCount, 0)
        await resolutionGate.release()
    }

    func testPresentationFreezeRejectsPendingForeignEpochDuplicateAndLogicalPathMismatch() async throws {
        let resolutionGate = CodemapResolutionGate()
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let firstRoot = try repositoryFixture.makeRepository(
            named: "first",
            files: ["Sources/First.swift": "struct First {}\n"]
        )
        let secondRoot = try repositoryFixture.makeRepository(
            named: "second",
            files: ["Sources/Second.swift": "struct Second {}\n"]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            resolutionGate: resolutionGate
        )
        addTeardownBlock {
            await resolutionGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let firstLoaded = try await store.loadRoot(path: firstRoot.path)
        let secondLoaded = try await store.loadRoot(path: secondRoot.path)
        let firstFiles = await store.files(inRoot: firstLoaded.id)
        let secondFiles = await store.files(inRoot: secondLoaded.id)
        let firstFile = try XCTUnwrap(firstFiles.first)
        let secondFile = try XCTUnwrap(secondFiles.first)
        let firstPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "First Logical Root",
            standardizedRelativePath: firstFile.standardizedRelativePath
        ))
        let secondPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Second Logical Root",
            standardizedRelativePath: secondFile.standardizedRelativePath
        ))
        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: firstFile.id)
        )
        let resolutionEntered = await resolutionGate.waitUntilEntered()
        XCTAssertTrue(resolutionEntered)

        await assertPresentationFreezeUnavailable(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: firstTicket, logicalPath: firstPath)
            ]),
            equals: .pending(firstTicket)
        )

        await resolutionGate.release()
        let firstReady = try await readyResult(
            settledResult(store: store, ticket: firstTicket)
        )
        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: secondFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: secondTicket))

        await assertPresentationFreezeUnavailable(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: firstTicket, logicalPath: firstPath),
                WorkspaceCodemapPresentationRequest(ticket: secondTicket, logicalPath: secondPath)
            ]),
            equals: .mixedRootEpoch
        )
        await assertPresentationFreezeUnavailable(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: firstTicket, logicalPath: firstPath),
                WorkspaceCodemapPresentationRequest(ticket: firstTicket, logicalPath: firstPath)
            ]),
            equals: .duplicateFileID(firstFile.id)
        )

        let mismatchedPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "First Logical Root",
            standardizedRelativePath: "Sources/Elsewhere.swift"
        ))
        await assertPresentationFreezeUnavailable(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(
                    ticket: firstTicket,
                    logicalPath: mismatchedPath
                )
            ]),
            equals: .logicalPathMismatch(firstFile.id)
        )

        let unretainedEntry = WorkspaceCodemapFrozenPresentationEntry(
            ticket: firstTicket,
            logicalPath: firstPath,
            artifactKey: firstReady.snapshot.artifactKey,
            outcome: firstReady.snapshot.outcome
        )
        let unretainedBundle = WorkspaceCodemapFrozenPresentationBundle(
            rootEpoch: firstTicket.rootEpoch,
            entries: [unretainedEntry],
            handles: [firstReady.handle]
        )
        await assertPresentationRenderUnavailable(
            store.renderCodemapPresentation(unretainedBundle),
            equals: .bundleNotRetained
        )

        let plainRoot = try fixture.makePlainRoot(files: [
            "Sources/Plain.swift": "struct Plain {}\n"
        ])
        let plainLoaded = try await store.loadRoot(path: plainRoot.path)
        let plainFiles = await store.files(inRoot: plainLoaded.id)
        let plainFile = try XCTUnwrap(plainFiles.first)
        let plainTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: plainFile.id)
        )
        let plainSettled = try await settledResult(store: store, ticket: plainTicket)
        assertNonGitTerminal(plainSettled)
        let plainPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Plain Logical Root",
            standardizedRelativePath: plainFile.standardizedRelativePath
        ))
        await assertPresentationFreezeUnavailable(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: plainTicket, logicalPath: plainPath)
            ]),
            equals: .demandUnavailable(plainTicket, .gitTerminal(.nonGit))
        )

        let validBundle = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: firstTicket, logicalPath: firstPath)
            ])
        )
        let validBundleReleased = await store.releaseCodemapPresentation(validBundle)
        XCTAssertTrue(validBundleReleased)
        await store.unloadRoot(id: firstLoaded.id)
        await store.unloadRoot(id: secondLoaded.id)
        await store.unloadRoot(id: plainLoaded.id)
    }

    func testPresentationRenderFailsClosedAfterDemandCancellationCatalogAdvanceAndUnload() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let cancellationRoot = try repositoryFixture.makeRepository(
            named: "cancellation",
            files: [
                "Sources/First.swift": "struct First {}\n",
                "Sources/Second.swift": "struct Second {}\n"
            ]
        )
        let catalogRoot = try repositoryFixture.makeRepository(
            named: "catalog",
            files: ["Sources/Catalog.swift": "struct Catalog {}\n"]
        )
        let unloadRoot = try repositoryFixture.makeRepository(
            named: "unload",
            files: ["Sources/Unload.swift": "struct Unload {}\n"]
        )
        let cancellationGate = CodemapSuspensionGate()
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await cancellationGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(cancellationCleanupHook: { _ in
            await cancellationGate.enterAndWait()
        })

        let cancellationLoaded = try await store.loadRoot(path: cancellationRoot.path)
        let cancellationFiles = await store.files(inRoot: cancellationLoaded.id)
            .sorted { $0.standardizedRelativePath < $1.standardizedRelativePath }
        XCTAssertEqual(cancellationFiles.count, 2)
        let firstCancellationTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: cancellationFiles[0].id)
        )
        _ = try await readyResult(
            settledResult(store: store, ticket: firstCancellationTicket)
        )
        let secondCancellationTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: cancellationFiles[1].id)
        )
        _ = try await readyResult(
            settledResult(store: store, ticket: secondCancellationTicket)
        )
        let cancellationBundle = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(
                    ticket: firstCancellationTicket,
                    logicalPath: XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
                        rootDisplayName: "Cancellation Logical Root",
                        standardizedRelativePath: cancellationFiles[0].standardizedRelativePath
                    ))
                ),
                WorkspaceCodemapPresentationRequest(
                    ticket: secondCancellationTicket,
                    logicalPath: XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
                        rootDisplayName: "Cancellation Logical Root",
                        standardizedRelativePath: cancellationFiles[1].standardizedRelativePath
                    ))
                )
            ])
        )

        let cancellationTask = Task {
            await store.cancelCodemapArtifactDemand(firstCancellationTicket)
        }
        let cancellationEntered = await cancellationGate.waitUntilEntered()
        XCTAssertTrue(cancellationEntered)
        await assertPresentationRenderUnavailable(
            store.renderCodemapPresentation(cancellationBundle),
            equals: .bundleNotRetained
        )
        await cancellationGate.release()
        let cancellationResult = await cancellationTask.value
        XCTAssertTrue(cancellationResult)

        let catalogLoaded = try await store.loadRoot(path: catalogRoot.path)
        let catalogFiles = await store.files(inRoot: catalogLoaded.id)
        let catalogFile = try XCTUnwrap(catalogFiles.first)
        let catalogTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: catalogFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: catalogTicket))
        let catalogPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Catalog Logical Root",
            standardizedRelativePath: catalogFile.standardizedRelativePath
        ))
        let releaseBundle = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: catalogTicket, logicalPath: catalogPath)
            ])
        )
        let catalogBundle = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: catalogTicket, logicalPath: catalogPath)
            ])
        )
        let firstRelease = await store.releaseCodemapPresentation(releaseBundle)
        let secondRelease = await store.releaseCodemapPresentation(releaseBundle)
        XCTAssertTrue(firstRelease)
        XCTAssertFalse(secondRelease)
        await assertPresentationRenderUnavailable(
            store.renderCodemapPresentation(releaseBundle),
            equals: .bundleNotRetained
        )

        try Self.write(
            "struct Added {}\n",
            to: catalogRoot.appendingPathComponent("Sources/Added.swift")
        )
        _ = await store.ensureIndexedFiles(paths: [
            catalogRoot.appendingPathComponent("Sources/Added.swift").path
        ])
        await assertPresentationRenderUnavailable(
            store.renderCodemapPresentation(catalogBundle),
            equals: .bundleNotRetained
        )

        let unloadLoaded = try await store.loadRoot(path: unloadRoot.path)
        let unloadFiles = await store.files(inRoot: unloadLoaded.id)
        let unloadFile = try XCTUnwrap(unloadFiles.first)
        let unloadTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: unloadFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: unloadTicket))
        let unloadBundle = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(
                    ticket: unloadTicket,
                    logicalPath: XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
                        rootDisplayName: "Unload Logical Root",
                        standardizedRelativePath: unloadFile.standardizedRelativePath
                    ))
                )
            ])
        )
        await store.unloadRoot(id: unloadLoaded.id)
        await assertPresentationRenderUnavailable(
            store.renderCodemapPresentation(unloadBundle),
            equals: .bundleNotRetained
        )

        await store.unloadRoot(id: cancellationLoaded.id)
        await store.unloadRoot(id: catalogLoaded.id)
    }

    func testAcceptedReadyOverlayLazilyBuildsOneExactEpochGraphAndReturnsPartial() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target {}\n",
                "Sources/Pending.swift": "struct Pending {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let firstPublicationGate = CodemapArmableSuspensionGate()
        let pendingPublicationGate = CodemapArmableSuspensionGate()
        let initialGraphPolicy = WorkspaceCodemapSelectionGraphRuntimePolicy.initial
        let graphProbe = CodemapSelectionGraphProbe(runtimePolicy: .init(
            maximumActiveRebuildCount: initialGraphPolicy.maximumActiveRebuildCount,
            maximumReservedBindingCount: initialGraphPolicy.maximumReservedBindingCount,
            maximumInputBindingCount: initialGraphPolicy.maximumInputBindingCount,
            maximumSelectedSourceCountPerQuery: 1,
            maximumResolvedTargetCountPerQuery: initialGraphPolicy.maximumResolvedTargetCountPerQuery,
            maximumReferenceFailureCountPerQuery: initialGraphPolicy.maximumReferenceFailureCountPerQuery,
            graphSizePolicy: initialGraphPolicy.graphSizePolicy
        ))
        addTeardownBlock {
            await firstPublicationGate.release()
            await pendingPublicationGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            readyPublicationHook: { _ in
                await firstPublicationGate.enterIfArmedAndWait()
                await pendingPublicationGate.enterIfArmedAndWait()
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let target = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Target.swift"
        })
        let pending = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Pending.swift"
        })

        await firstPublicationGate.arm()
        let sourceTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: source.id)
        )
        let firstPublicationEntered = await firstPublicationGate.waitUntilEntered()
        XCTAssertTrue(firstPublicationEntered)
        XCTAssertEqual(graphProbe.factoryCount, 0)
        await firstPublicationGate.release()
        _ = try await readyResult(settledResult(store: store, ticket: sourceTicket))

        let targetTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: target.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: targetTicket))
        let sourceQuery = WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
            WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: sourceTicket)
        ])
        let result = try await readyGraphQuery(store: store, query: sourceQuery)
        XCTAssertEqual(result.roots.count, 1)
        let rootResult = try XCTUnwrap(result.roots.first)
        XCTAssertEqual(rootResult.rootEpoch, sourceTicket.rootEpoch)
        XCTAssertEqual(rootResult.result.key.rootEpoch, sourceTicket.rootEpoch)
        XCTAssertTrue(rootResult.partialReasons.contains(.definitionUniverseIncomplete))
        XCTAssertEqual(rootResult.result.publishedSummary.nodeCount, 2)
        XCTAssertTrue(rootResult.result.targets.allSatisfy {
            $0.rootEpoch == sourceTicket.rootEpoch
        })
        XCTAssertTrue(rootResult.result.resolutions.allSatisfy {
            $0.source.rootEpoch == sourceTicket.rootEpoch &&
                $0.target.rootEpoch == sourceTicket.rootEpoch
        })
        XCTAssertEqual(graphProbe.factoryCount, 1)
        let budgetedQuery = await store.queryCodemapSelectionGraph(
            WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: sourceTicket),
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: targetTicket)
            ])
        )
        XCTAssertEqual(
            budgetedQuery,
            .budget(.runtime(
                rootEpoch: sourceTicket.rootEpoch,
                reason: .budgetExceeded
            ))
        )

        await pendingPublicationGate.arm()
        let pendingTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: pending.id)
        )
        let pendingPublicationEntered = await pendingPublicationGate.waitUntilEntered()
        XCTAssertTrue(pendingPublicationEntered)
        let whilePending = try await readyGraphQuery(store: store, query: sourceQuery)
        XCTAssertFalse(whilePending.roots.flatMap(\.result.targets).contains {
            $0.fileID == pending.id
        })
        let pendingQuery = await store.queryCodemapSelectionGraph(
            WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: pendingTicket)
            ])
        )
        XCTAssertEqual(pendingQuery, .unavailable(.sourceNotReady(pending.id)))
        XCTAssertEqual(graphProbe.factoryCount, 1)
        await pendingPublicationGate.release()
        _ = try await readyResult(settledResult(store: store, ticket: pendingTicket))

        try Self.write(
            "struct CatalogAdvance {}\n",
            to: root.appendingPathComponent("Sources/CatalogAdvance.swift")
        )
        _ = await store.ensureIndexedFiles(paths: [
            root.appendingPathComponent("Sources/CatalogAdvance.swift").path
        ])
        let staleAfterCatalogAdvance = await store.queryCodemapSelectionGraph(sourceQuery)
        XCTAssertEqual(
            staleAfterCatalogAdvance,
            .stale(.currentness(sourceTicket.rootEpoch))
        )
        await store.unloadRoot(id: loaded.id)
    }

    func testGraphQueryRejectsForeignEpochAndUnreadySourcesWithoutCrossRootTargets() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let firstRoot = try firstRepository.makeRepository(
            named: "same-name",
            files: [
                "Sources/ForeignReference.swift":
                    "struct ForeignReference { let value: SharedDefinition }\n"
            ]
        )
        let secondRoot = try secondRepository.makeRepository(
            named: "same-name",
            files: [
                "Sources/SharedDefinition.swift": "struct SharedDefinition {}\n"
            ]
        )
        XCTAssertEqual(firstRoot.lastPathComponent, secondRoot.lastPathComponent)

        let fixture = try CodemapStoreFixture(name: #function)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let firstLoaded = try await store.loadRoot(path: firstRoot.path)
        let secondLoaded = try await store.loadRoot(path: secondRoot.path)
        let firstFiles = await store.files(inRoot: firstLoaded.id)
        let secondFiles = await store.files(inRoot: secondLoaded.id)
        let firstFile = try XCTUnwrap(firstFiles.first)
        let secondFile = try XCTUnwrap(secondFiles.first)
        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: firstFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: firstTicket))
        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: secondFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: secondTicket))

        let firstOnly = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: firstTicket)
            ])
        )
        XCTAssertEqual(firstOnly.roots.count, 1)
        let firstRootResult = try XCTUnwrap(firstOnly.roots.first)
        XCTAssertFalse(firstRootResult.result.targets.contains {
            $0.fileID == secondFile.id
        })
        XCTAssertTrue(firstRootResult.result.targets.allSatisfy {
            $0.rootEpoch == firstTicket.rootEpoch
        })

        let combined = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: secondTicket),
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: firstTicket)
            ])
        )
        XCTAssertEqual(Set(combined.roots.map(\.rootEpoch)), [
            firstTicket.rootEpoch,
            secondTicket.rootEpoch
        ])
        for rootResult in combined.roots {
            XCTAssertTrue(rootResult.result.targets.allSatisfy {
                $0.rootEpoch == rootResult.rootEpoch
            })
            XCTAssertTrue(rootResult.result.resolutions.allSatisfy {
                $0.source.rootEpoch == rootResult.rootEpoch &&
                    $0.target.rootEpoch == rootResult.rootEpoch
            })
        }
        XCTAssertEqual(graphProbe.factoryCount, 2)

        let foreign = await store.queryCodemapSelectionGraph(
            WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(
                    rootEpoch: secondTicket.rootEpoch,
                    ticket: firstTicket
                )
            ])
        )
        XCTAssertEqual(foreign, .unavailable(.foreignRootEpoch(firstFile.id)))

        let resolutionGate = CodemapResolutionGate()
        let pendingFixture = try CodemapStoreFixture(
            name: #function + "-pending",
            resolutionGate: resolutionGate
        )
        let pendingProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await resolutionGate.release()
            await pendingFixture.shutdown()
        }
        let pendingStore = pendingFixture.makeStore(selectionGraphFactory: pendingProbe.factory)
        let pendingLoaded = try await pendingStore.loadRoot(path: firstRoot.path)
        let pendingFiles = await pendingStore.files(inRoot: pendingLoaded.id)
        let pendingFile = try XCTUnwrap(pendingFiles.first)
        let unreadyTicket = try await pendingTicket(
            pendingStore.requestCodemapArtifact(forFileID: pendingFile.id)
        )
        let resolutionEntered = await resolutionGate.waitUntilEntered()
        XCTAssertTrue(resolutionEntered)
        let unready = await pendingStore.queryCodemapSelectionGraph(
            WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: unreadyTicket)
            ])
        )
        XCTAssertEqual(unready, .unavailable(.sourceNotReady(pendingFile.id)))
        XCTAssertEqual(pendingProbe.factoryCount, 0)
        await resolutionGate.release()
        _ = try await settledResult(store: pendingStore, ticket: unreadyTicket)
        await pendingStore.unloadRoot(id: pendingLoaded.id)

        await store.unloadRoot(id: firstLoaded.id)
        await store.unloadRoot(id: secondLoaded.id)
    }

    func testMultiRootGraphQueryEnforcesAggregateBudgetBeforeNPlusOneMaterialization() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let thirdRepository = try ReviewGitRepositoryFixture(name: #function + "-third")
        let firstRoot = try firstRepository.makeRepository(
            named: "first",
            files: ["Sources/Source.swift": "struct First { let value: MissingFirst }\n"]
        )
        let secondRoot = try secondRepository.makeRepository(
            named: "second",
            files: ["Sources/Source.swift": "struct Second { let value: MissingSecond }\n"]
        )
        let thirdRoot = try thirdRepository.makeRepository(
            named: "third",
            files: ["Sources/Source.swift": "struct Third { let value: MissingThird }\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
            thirdRepository.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            selectionGraphQueryBudgetPolicy: .init(
                maximumTargetCount: 100,
                maximumResolutionCount: 100,
                maximumReferenceFailureCount: 100,
                maximumByteCount: 521
            )
        )

        var loadedRoots: [WorkspaceRootRecord] = []
        var tickets: [WorkspaceCodemapArtifactDemandTicket] = []
        for root in [firstRoot, secondRoot, thirdRoot] {
            let loaded = try await store.loadRoot(path: root.path)
            loadedRoots.append(loaded)
            let files = await store.files(inRoot: loaded.id)
            let file = try XCTUnwrap(files.first)
            let ticket = try await pendingTicket(
                store.requestCodemapArtifact(forFileID: file.id)
            )
            _ = try await readyResult(settledResult(store: store, ticket: ticket))
            tickets.append(ticket)
        }
        for ticket in tickets {
            let published = await graphProbe.waitUntilPublished(rootEpoch: ticket.rootEpoch)
            XCTAssertTrue(published)
        }

        let firstTwoQuery = WorkspaceCodemapStoreSelectionGraphQuery(
            selectedSources: tickets
                .prefix(2)
                .map(WorkspaceCodemapStoreSelectionGraphSourceIdentity.init(ticket:))
        )
        let firstTwo = await store.queryCodemapSelectionGraph(firstTwoQuery)
        guard case let .readyPartial(firstTwoResult) = firstTwo else {
            return XCTFail("Expected the N-root query to fit the aggregate budget.")
        }
        XCTAssertEqual(firstTwoResult.roots.count, 2)
        XCTAssertEqual(
            firstTwoResult.roots.reduce(0) { $0 + $1.result.referenceFailures.count },
            2
        )
        let afterNMaterializations = await graphProbe.materializedQueryResultCount()
        XCTAssertEqual(afterNMaterializations, 2)

        let nPlusOneQuery = WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: tickets.map(
            WorkspaceCodemapStoreSelectionGraphSourceIdentity.init(ticket:)
        ))
        let nPlusOne = await store.queryCodemapSelectionGraph(nPlusOneQuery)
        XCTAssertEqual(
            nPlusOne,
            .budget(.byteLimit(attempted: 522, limit: 521))
        )
        let afterNPlusOneMaterializations = await graphProbe.materializedQueryResultCount()
        XCTAssertEqual(afterNPlusOneMaterializations - afterNMaterializations, 2)

        let automaticSources = tickets.map {
            WorkspaceCodemapAutomaticSelectionSourceIdentity(
                rootEpoch: $0.rootEpoch,
                fileID: $0.fileID,
                catalogGeneration: $0.catalogGeneration
            )
        }
        let beforeAutomaticN = await graphProbe.materializedQueryResultCount()
        let automaticN = try await store.resolveAutomaticCodemapSelection(
            sources: Array(automaticSources.prefix(2)),
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(automaticN.roots.count, 2)
        let afterAutomaticN = await graphProbe.materializedQueryResultCount()
        XCTAssertEqual(afterAutomaticN - beforeAutomaticN, 2)

        let automaticNPlusOne = try await store.resolveAutomaticCodemapSelection(
            sources: automaticSources,
            rootScope: .visibleWorkspace
        )
        XCTAssertTrue(automaticNPlusOne.roots.isEmpty)
        XCTAssertTrue(automaticNPlusOne.targets.isEmpty)
        XCTAssertNil(automaticNPlusOne.publicationReceipt)
        XCTAssertEqual(
            automaticNPlusOne.aggregateCoverage,
            .budget(.byteLimit(attempted: 522, limit: 521))
        )
        let afterAutomaticNPlusOne = await graphProbe.materializedQueryResultCount()
        XCTAssertEqual(afterAutomaticNPlusOne - afterAutomaticN, 2)

        for loaded in loadedRoots {
            await store.unloadRoot(id: loaded.id)
        }
    }

    func testGraphUpdateHidesQueuedContributionAndUnloadRevokesBlockedBuild() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/First.swift": "struct First {}\n",
                "Sources/Second.swift": "struct Second { let first: First }\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let buildGate = CodemapSelectionGraphBuildGate()
        let graphProbe = CodemapSelectionGraphProbe(buildGate: buildGate)
        addTeardownBlock {
            buildGate.releaseAll()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let first = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/First.swift"
        })
        let second = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Second.swift"
        })
        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: first.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: firstTicket))
        let blockedGeneration = try XCTUnwrap(buildGate.waitUntilFirstBlocked())
        let oldGraph = try XCTUnwrap(graphProbe.graph(rootEpoch: firstTicket.rootEpoch))
        let firstQuery = WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
            WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: firstTicket)
        ])
        let whileInitialBuildQueued = await store.queryCodemapSelectionGraph(firstQuery)
        XCTAssertEqual(
            whileInitialBuildQueued,
            .busy(.runtime(
                rootEpoch: firstTicket.rootEpoch,
                reason: .rebuilding
            ))
        )

        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: second.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: secondTicket))
        let query = WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
            WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: firstTicket)
        ])
        let queryClock = ContinuousClock()
        let queryStarted = queryClock.now
        let whileNewerContributionQueued = await store.queryCodemapSelectionGraph(query)
        let queryDuration = queryStarted.duration(to: queryClock.now)
        guard case .stale(.runtime(
            rootEpoch: firstTicket.rootEpoch,
            reason: .staleCurrentness
        )) = whileNewerContributionQueued else {
            return XCTFail("Expected the newer desired contribution to hide the queued older shard.")
        }
        XCTAssertLessThan(queryDuration, .seconds(1))

        let unloadTask = Task {
            await store.unloadRoot(id: loaded.id)
        }
        let afterRevocation = await store.queryCodemapSelectionGraph(query)
        XCTAssertEqual(afterRevocation, .stale(.currentness(firstTicket.rootEpoch)))
        buildGate.release(generation: blockedGeneration)
        buildGate.releaseAll()
        await unloadTask.value

        let oldAccounting = await oldGraph.accounting()
        XCTAssertEqual(oldAccounting.publishedCount, 0)
        XCTAssertEqual(oldAccounting.emptyPublishedCount, 0)
        XCTAssertEqual(
            oldAccounting.currentUnavailableReason,
            .explicitRootUnavailable(.rootUnloaded)
        )

        let reloaded = try await store.loadRoot(path: root.path)
        let reloadedFiles = await store.files(inRoot: reloaded.id)
        let reloadedFirst = try XCTUnwrap(reloadedFiles.first {
            $0.standardizedRelativePath == "Sources/First.swift"
        })
        let reloadedTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: reloadedFirst.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: reloadedTicket))
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: reloadedTicket)
            ])
        )
        XCTAssertNotEqual(reloadedTicket.rootEpoch, firstTicket.rootEpoch)
        XCTAssertEqual(graphProbe.factoryCount, 2)
        let oldLifetimeQuery = await store.queryCodemapSelectionGraph(query)
        XCTAssertEqual(oldLifetimeQuery, .stale(.currentness(firstTicket.rootEpoch)))
        await store.unloadRoot(id: reloaded.id)
    }

    func testNonGitDemandBecomesTerminalWithoutSourceReadManifestBuildOrGraphWork() async throws {
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock { await fixture.shutdown() }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let graphProbe = CodemapSelectionGraphProbe()
        let preflightCount = CodemapLockedCounter()
        let store = fixture.makeStore(
            codemapGitEligibilityProbe: WorkspaceCodemapGitEligibilityProbe { _ in
                preflightCount.increment()
                return .terminalUnavailable(.nonGit)
            },
            selectionGraphFactory: graphProbe.factory
        )
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let first = await store.requestCodemapArtifact(forFileID: file.id)
        let second = await store.requestCodemapArtifact(forFileID: file.id)
        assertNonGitTerminal(first)
        assertNonGitTerminal(second)
        XCTAssertEqual(preflightCount.value, 1)
        let firstOperationCounts = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(firstOperationCounts.setupTasksCreated, 0)
        XCTAssertEqual(firstOperationCounts.demandTasksCreated, 0)

        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 0)
        XCTAssertEqual(fixture.engineFactoryCount.value, 0)
        XCTAssertEqual(fixture.manifestReadCount.value, 0)
        XCTAssertEqual(fixture.buildCount.value, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)

        await store.unloadRoot(id: loaded.id)
        let reloaded = try await store.loadRoot(path: root.path)
        let reloadedFiles = await store.files(inRoot: reloaded.id)
        let reloadedFile = try XCTUnwrap(reloadedFiles.first)
        await assertNonGitTerminal(store.requestCodemapArtifact(forFileID: reloadedFile.id))
        XCTAssertEqual(preflightCount.value, 2)
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 0)
        XCTAssertEqual(fixture.engineFactoryCount.value, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)
        let reloadedOperationCounts = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(reloadedOperationCounts.setupTasksCreated, 0)
        XCTAssertEqual(reloadedOperationCounts.demandTasksCreated, 0)
        await store.unloadRoot(id: reloaded.id)
    }

    func testNonGitPresentationPlanStartsNoCodemapRuntimeDemandBuildOrCASWork() async throws {
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock { await fixture.shutdown() }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let store = fixture.makeStore(codemapGitEligibilityProbe: .production())
        _ = try await store.loadRoot(path: root.path)

        let plan = await WorkspaceCodemapPresentationIntentResolver.plan(
            codeMapUsage: .selected,
            selection: StoredSelection(
                selectedPaths: ["Sources/Feature.swift"],
                codemapAutoEnabled: false
            ),
            store: store,
            rootScope: .allLoaded,
            profile: .uiAssisted
        )
        let presentation = try await WorkspaceCodemapPresentationCoordinator(store: store)
            .presentation(for: plan.intent, rootScope: .allLoaded)
        let merged = WorkspaceCodemapPresentationIntentResolver.merging(
            presentation,
            preflightIssues: plan.preflightIssues
        )

        XCTAssertTrue(merged.orderedEntries.isEmpty)
        XCTAssertTrue(merged.issues.contains {
            if case .unavailable(_, .gitTerminal(.nonGit)) = $0 { return true }
            return false
        })
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 0)
        XCTAssertEqual(fixture.engineFactoryCount.value, 0)
        XCTAssertEqual(fixture.manifestReadCount.value, 0)
        XCTAssertEqual(fixture.buildCount.value, 0)
    }

    func testCatalogAdvanceFencesPendingTicketAndExactRegistryRoute() async throws {
        let gate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(name: #function, resolutionGate: gate)
        addTeardownBlock {
            await gate.release()
            await fixture.shutdown()
        }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let gateEntered = await gate.waitUntilEntered()
        XCTAssertTrue(gateEntered)

        let routed = await fixture.registry.makeBindingCatalogClient()
            .resolveManifestBinding(ticket.rootEpoch, file.standardizedRelativePath)
        XCTAssertEqual(routed?.identity.fileID, file.id)

        try Self.write("struct Added {}\n", to: root.appendingPathComponent("Sources/Added.swift"))
        let replayTask = Task {
            await store.ensureIndexedFiles(paths: [
                root.appendingPathComponent("Sources/Added.swift").path
            ])
        }

        let routeUnavailable = await routeBecomesUnavailable(
            registry: fixture.registry,
            ticket: ticket,
            relativePath: file.standardizedRelativePath
        )
        XCTAssertTrue(routeUnavailable)
        await assertStale(store.codemapArtifactDemandStatus(ticket))
        await gate.release()
        await replayTask.value
        try await assertEngineRootCount(0, fixture: fixture)
        await store.unloadRoot(id: loaded.id)
    }

    func testUnloadAndReloadFenceOldLifetimeAndDrainCodemapRootState() async throws {
        let gate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(name: #function, resolutionGate: gate)
        addTeardownBlock {
            await gate.release()
            await fixture.shutdown()
        }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let store = fixture.makeStore()
        let firstRoot = try await store.loadRoot(path: root.path)
        let firstFiles = await store.files(inRoot: firstRoot.id)
        let firstFile = try XCTUnwrap(firstFiles.first)
        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: firstFile.id)
        )
        let gateEntered = await gate.waitUntilEntered()
        XCTAssertTrue(gateEntered)

        let unloadTask = Task {
            await store.unloadRoot(id: firstRoot.id)
        }
        let routeUnavailable = await routeBecomesUnavailable(
            registry: fixture.registry,
            ticket: firstTicket,
            relativePath: firstFile.standardizedRelativePath
        )
        XCTAssertTrue(routeUnavailable)
        await assertStale(store.codemapArtifactDemandStatus(firstTicket))
        await gate.release()
        await unloadTask.value

        let secondRoot = try await store.loadRoot(path: root.path)
        let secondFiles = await store.files(inRoot: secondRoot.id)
        let secondFile = try XCTUnwrap(secondFiles.first)
        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: secondFile.id)
        )

        XCTAssertNotEqual(secondRoot.id, firstRoot.id)
        XCTAssertNotEqual(secondTicket.rootEpoch, firstTicket.rootEpoch)
        await assertStale(store.codemapArtifactDemandStatus(firstTicket))
        try await assertNonGitTerminal(settledResult(store: store, ticket: secondTicket))
        await store.unloadRoot(id: secondRoot.id)
        let engineRootCountIsZero = try await engineRootCountBecomesZero(fixture: fixture)
        XCTAssertTrue(engineRootCountIsZero)
    }

    func testReadyDemandsReuseInjectedRuntimeRegistryAndEngineSingletons() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/First.swift": "struct First {}\n",
                "Sources/Second.swift": "struct Second {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let firstFile = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/First.swift"
        })
        let secondFile = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Second.swift"
        })

        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: firstFile.id)
        )
        let firstReady = try await readyResult(
            settledResult(store: store, ticket: firstTicket)
        )
        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: secondFile.id)
        )
        let secondReady = try await readyResult(
            settledResult(store: store, ticket: secondTicket)
        )

        XCTAssertEqual(firstTicket.rootEpoch, secondTicket.rootEpoch)
        XCTAssertEqual(firstReady.identity.fileID, firstFile.id)
        XCTAssertEqual(firstReady.snapshot.fileID, firstFile.id)
        XCTAssertEqual(try firstReady.handle.artifactKey(), firstReady.snapshot.artifactKey)
        XCTAssertEqual(secondReady.identity.fileID, secondFile.id)
        XCTAssertEqual(secondReady.snapshot.fileID, secondFile.id)
        XCTAssertEqual(try secondReady.handle.artifactKey(), secondReady.snapshot.artifactKey)
        XCTAssertEqual(fixture.providerAccessCount.value, 1)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 1)
        XCTAssertEqual(fixture.engineFactoryCount.value, 1)
        XCTAssertTrue(try fixture.runtime().bindingIntegrationRegistry === fixture.registry)

        let firstCandidate = await fixture.registry.makeBindingCatalogClient()
            .resolveManifestBinding(
                firstTicket.rootEpoch,
                firstFile.standardizedRelativePath
            )
        let secondCandidate = await fixture.registry.makeBindingCatalogClient()
            .resolveManifestBinding(
                secondTicket.rootEpoch,
                secondFile.standardizedRelativePath
            )
        XCTAssertEqual(firstCandidate?.identity.fileID, firstFile.id)
        XCTAssertEqual(secondCandidate?.identity.fileID, secondFile.id)

        await store.unloadRoot(id: loaded.id)
        XCTAssertThrowsError(try firstReady.handle.artifactKey()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }
        XCTAssertThrowsError(try secondReady.handle.artifactKey()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }
    }

    func testCancellationAfterReadyRevokesRetainedHandleIdempotently() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let ready = try await readyResult(
            settledResult(store: store, ticket: ticket)
        )
        let runtime = try fixture.runtime()
        let accountingBeforeCancellation = await runtime.artifactStore.accounting()
        XCTAssertEqual(accountingBeforeCancellation.activeLeaseCount, 1)
        XCTAssertGreaterThan(accountingBeforeCancellation.activeLeaseBytes, 0)

        let firstCancellation = await store.cancelCodemapArtifactDemand(ticket)
        XCTAssertTrue(firstCancellation)
        await assertStale(store.codemapArtifactDemandStatus(ticket))
        XCTAssertThrowsError(try ready.handle.artifactKey()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }
        let accountingAfterFirstCancellation = await runtime.artifactStore.accounting()
        XCTAssertEqual(accountingAfterFirstCancellation.activeLeaseCount, 1)
        XCTAssertEqual(
            accountingAfterFirstCancellation.activeLeaseBytes,
            accountingBeforeCancellation.activeLeaseBytes
        )

        let secondCancellation = await store.cancelCodemapArtifactDemand(ticket)
        XCTAssertFalse(secondCancellation)
        await assertStale(store.codemapArtifactDemandStatus(ticket))
        XCTAssertThrowsError(try ready.handle.artifactKey()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }
        let accountingAfterSecondCancellation = await runtime.artifactStore.accounting()
        XCTAssertEqual(accountingAfterSecondCancellation.activeLeaseCount, 1)
        XCTAssertEqual(
            accountingAfterSecondCancellation.activeLeaseBytes,
            accountingBeforeCancellation.activeLeaseBytes
        )

        await store.unloadRoot(id: loaded.id)
    }

    func testReadyCancellationCleanupCannotCancelSamePathSuccessor() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let cancellationGate = CodemapSuspensionGate()
        let successorPublicationGate = CodemapArmableSuspensionGate()
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await cancellationGate.release()
            await successorPublicationGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            cancellationCleanupHook: { _ in
                await cancellationGate.enterAndWait()
            },
            readyPublicationHook: { _ in
                await successorPublicationGate.enterIfArmedAndWait()
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let cancelledTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let cancelledReady = try await readyResult(
            settledResult(store: store, ticket: cancelledTicket)
        )
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: cancelledTicket)
            ])
        )
        let epochGraph = try XCTUnwrap(graphProbe.graph(rootEpoch: cancelledTicket.rootEpoch))
        XCTAssertEqual(graphProbe.factoryCount, 1)
        await successorPublicationGate.arm()

        let cancellationTask = Task {
            await store.cancelCodemapArtifactDemand(cancelledTicket)
        }
        let cancellationEntered = await cancellationGate.waitUntilEntered()
        XCTAssertTrue(cancellationEntered)
        await assertCancelled(store.codemapArtifactDemandStatus(cancelledTicket))
        XCTAssertThrowsError(try cancelledReady.handle.artifactKey()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }

        let successorTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        XCTAssertNotEqual(successorTicket, cancelledTicket)
        let successorPublicationEntered = await successorPublicationGate.waitUntilEntered()
        XCTAssertTrue(successorPublicationEntered)

        await cancellationGate.release()
        let cancellationResult = await cancellationTask.value
        XCTAssertTrue(cancellationResult)
        await successorPublicationGate.release()
        let successorReady = try await readyResult(
            settledResult(store: store, ticket: successorTicket)
        )
        XCTAssertEqual(successorReady.ticket, successorTicket)
        XCTAssertEqual(try successorReady.handle.artifactKey(), successorReady.snapshot.artifactKey)
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: successorTicket)
            ])
        )
        XCTAssertTrue(graphProbe.graph(rootEpoch: successorTicket.rootEpoch) === epochGraph)
        XCTAssertEqual(graphProbe.factoryCount, 1)

        await store.unloadRoot(id: loaded.id)
        let reloaded = try await store.loadRoot(path: root.path)
        let reloadedFiles = await store.files(inRoot: reloaded.id)
        let reloadedFile = try XCTUnwrap(reloadedFiles.first)
        let reloadedTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: reloadedFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: reloadedTicket))
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: reloadedTicket)
            ])
        )
        XCTAssertNotEqual(reloadedTicket.rootEpoch, successorTicket.rootEpoch)
        XCTAssertEqual(graphProbe.factoryCount, 2)
        await store.unloadRoot(id: reloaded.id)
    }

    func testWatcherRenamePairFencesOnlyOldAndNewPaths() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Old.swift": "struct Old {}\n",
                "Sources/Unrelated.swift": "func unrelated() {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let old = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Old.swift" })
        let unrelated = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Unrelated.swift" })
        let oldTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: old.id))
        let oldReady = try await readyResult(settledResult(store: store, ticket: oldTicket))
        let unrelatedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: unrelated.id))
        let unrelatedReady = try await readyResult(settledResult(store: store, ticket: unrelatedTicket))
        let unrelatedPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Workspace",
            standardizedRelativePath: unrelated.standardizedRelativePath
        ))
        let unrelatedPresentation = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: unrelatedTicket, logicalPath: unrelatedPath)
            ])
        )
        let unrelatedQuery = WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
            WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: unrelatedTicket)
        ])
        _ = try await readyGraphQuery(store: store, query: unrelatedQuery)

        try FileManager.default.moveItem(
            at: root.appendingPathComponent(old.standardizedRelativePath),
            to: root.appendingPathComponent("Sources/New.swift")
        )
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [
                .fileRemoved(old.standardizedRelativePath),
                .fileAdded("Sources/New.swift")
            ]
        )

        await assertStale(store.codemapArtifactDemandStatus(oldTicket))
        XCTAssertThrowsError(try oldReady.handle.artifactKey())
        XCTAssertEqual(try unrelatedReady.handle.artifactKey(), unrelatedReady.snapshot.artifactKey)
        _ = try await renderedPresentationEntries(
            store.renderCodemapPresentation(unrelatedPresentation)
        )
        _ = try await readyGraphQuery(store: store, query: unrelatedQuery)
        XCTAssertEqual(graphProbe.factoryCount, 1)

        let renamedValue = await store.file(rootID: loaded.id, relativePath: "Sources/New.swift")
        let renamed = try XCTUnwrap(renamedValue)
        let renamedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: renamed.id))
        XCTAssertGreaterThan(renamedTicket.pathGeneration, oldTicket.pathGeneration)
        _ = try await readyResult(settledResult(store: store, ticket: renamedTicket))
        await store.unloadRoot(id: loaded.id)
    }

    func testPathRepairPublishesReadyContributionCompletedDuringRebuild() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Affected.swift": "struct Affected {}\n",
                "Sources/Late.swift": "struct Late { let survivor: Survivor }\n",
                "Sources/Survivor.swift": "struct Survivor {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let buildGate = CodemapSelectionGraphBuildGate()
        let graphProbe = CodemapSelectionGraphProbe(buildGate: buildGate)
        addTeardownBlock {
            buildGate.releaseAll()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let affected = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Affected.swift" })
        let late = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Late.swift" })
        let survivor = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Survivor.swift" })
        let survivorTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: survivor.id))
        _ = try await readyResult(settledResult(store: store, ticket: survivorTicket))
        let initialGeneration = try XCTUnwrap(buildGate.waitUntilFirstBlocked())
        buildGate.release(generation: initialGeneration)
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: survivorTicket)
            ])
        )

        try Self.write(
            "struct Affected { let changed = true }\n",
            to: root.appendingPathComponent(affected.standardizedRelativePath)
        )
        let repairTask = Task {
            await store.replayObservedFileSystemDeltas(
                rootID: loaded.id,
                deltas: [.fileModified(affected.standardizedRelativePath, nil)]
            )
        }
        let repairGeneration = try XCTUnwrap(
            buildGate.waitUntilBlocked(after: initialGeneration)
        )

        let lateTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: late.id))
        _ = try await readyResult(settledResult(store: store, ticket: lateTicket))
        buildGate.release(generation: repairGeneration)
        buildGate.releaseAll()
        await repairTask.value

        let result = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: lateTicket)
            ])
        )
        let rootResult = try XCTUnwrap(result.roots.first)
        XCTAssertEqual(rootResult.result.publishedSummary.nodeCount, 2)
        XCTAssertTrue(rootResult.result.sourceCoverage.contains {
            $0.source.fileID == late.id && $0.state == .covered
        })
        await store.unloadRoot(id: loaded.id)
    }

    func testWatcherModifyDeleteAndGapAwaitPresentationGraphAndEngineFences() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Affected.swift": "func affected() {}\n",
                "Sources/Unrelated.swift": "func unrelated() {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let affected = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Affected.swift" })
        let unrelated = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Unrelated.swift" })
        let affectedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: affected.id))
        let affectedReady = try await readyResult(settledResult(store: store, ticket: affectedTicket))
        let unrelatedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: unrelated.id))
        let unrelatedReady = try await readyResult(settledResult(store: store, ticket: unrelatedTicket))
        let unrelatedPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Workspace",
            standardizedRelativePath: unrelated.standardizedRelativePath
        ))
        let unrelatedPresentation = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: unrelatedTicket, logicalPath: unrelatedPath)
            ])
        )
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: affectedTicket),
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: unrelatedTicket)
            ])
        )
        let graph = try XCTUnwrap(graphProbe.graph(rootEpoch: affectedTicket.rootEpoch))

        try Self.write(
            "struct Affected { let changed = true }\n",
            to: root.appendingPathComponent(affected.standardizedRelativePath)
        )
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [.fileModified(affected.standardizedRelativePath, nil)]
        )

        await assertStale(store.codemapArtifactDemandStatus(affectedTicket))
        XCTAssertThrowsError(try affectedReady.handle.artifactKey())
        XCTAssertEqual(try unrelatedReady.handle.artifactKey(), unrelatedReady.snapshot.artifactKey)
        _ = try await renderedPresentationEntries(
            store.renderCodemapPresentation(unrelatedPresentation)
        )
        let unrelatedGraph = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: unrelatedTicket)
            ])
        )
        XCTAssertEqual(unrelatedGraph.roots.first?.rootEpoch, unrelatedTicket.rootEpoch)
        XCTAssertEqual(graphProbe.factoryCount, 1)
        try await assertEngineRootCount(1, fixture: fixture)

        let successorTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: affected.id))
        XCTAssertGreaterThan(successorTicket.pathGeneration, affectedTicket.pathGeneration)
        _ = try await readyResult(settledResult(store: store, ticket: successorTicket))
        try FileManager.default.removeItem(at: root.appendingPathComponent(unrelated.standardizedRelativePath))
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [.fileRemoved(unrelated.standardizedRelativePath)]
        )
        await assertStale(store.codemapArtifactDemandStatus(unrelatedTicket))
        XCTAssertThrowsError(try unrelatedReady.handle.artifactKey())

        await store.replayPublisherFileSystemPublicationForTesting(
            rootID: loaded.id,
            expectedLifetimeID: successorTicket.rootEpoch.rootLifetimeID,
            deltas: [],
            requiresFullResync: true
        )
        await assertStale(store.codemapArtifactDemandStatus(successorTicket))
        try await assertEngineRootCount(1, fixture: fixture)
        let graphAccounting = await graph.accounting()
        XCTAssertEqual(graphAccounting.currentUnavailableReason, .explicitRootUnavailable(.authorityRevoked))
        XCTAssertEqual(graphAccounting.activeRebuildCount, 0)
        let route = await fixture.registry.makeBindingCatalogClient().resolveManifestBinding(
            successorTicket.rootEpoch,
            affected.standardizedRelativePath
        )
        XCTAssertNil(route)
        await store.unloadRoot(id: loaded.id)
    }

    func testStoreEditRenameAndDeleteAwaitCodemapAuthorityFenceBeforeReturning() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Mutable.swift": "struct Mutable {}\n",
                "Sources/Unrelated.swift": "struct Unrelated {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let initialFiles = await store.files(inRoot: loaded.id)
        let mutable = try XCTUnwrap(initialFiles.first { $0.standardizedRelativePath == "Sources/Mutable.swift" })
        let unrelated = try XCTUnwrap(initialFiles.first { $0.standardizedRelativePath == "Sources/Unrelated.swift" })
        let mutableTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: mutable.id))
        _ = try await readyResult(settledResult(store: store, ticket: mutableTicket))
        let unrelatedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: unrelated.id))
        let unrelatedReady = try await readyResult(settledResult(store: store, ticket: unrelatedTicket))
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: unrelatedTicket)
            ])
        )

        _ = try await store.editFile(
            rootID: loaded.id,
            relativePath: mutable.standardizedRelativePath,
            newContent: "struct Mutable { let edited = true }\n"
        )
        await assertStale(store.codemapArtifactDemandStatus(mutableTicket))
        XCTAssertEqual(try unrelatedReady.handle.artifactKey(), unrelatedReady.snapshot.artifactKey)

        let editedFileValue = await store.file(
            rootID: loaded.id,
            relativePath: mutable.standardizedRelativePath
        )
        let editedFile = try XCTUnwrap(editedFileValue)
        let editedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: editedFile.id))
        _ = try await readyResult(settledResult(store: store, ticket: editedTicket))
        try await store.moveFile(
            rootID: loaded.id,
            from: mutable.standardizedRelativePath,
            to: "Sources/Renamed.swift"
        )
        await assertStale(store.codemapArtifactDemandStatus(editedTicket))
        XCTAssertEqual(try unrelatedReady.handle.artifactKey(), unrelatedReady.snapshot.artifactKey)

        let renamedFileValue = await store.file(
            rootID: loaded.id,
            relativePath: "Sources/Renamed.swift"
        )
        let renamedFile = try XCTUnwrap(renamedFileValue)
        let renamedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: renamedFile.id))
        _ = try await readyResult(settledResult(store: store, ticket: renamedTicket))
        try await store.deleteFile(rootID: loaded.id, relativePath: "Sources/Renamed.swift")
        await assertStale(store.codemapArtifactDemandStatus(renamedTicket))
        XCTAssertEqual(try unrelatedReady.handle.artifactKey(), unrelatedReady.snapshot.artifactKey)
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: unrelatedTicket)
            ])
        )
        try await assertEngineRootCount(1, fixture: fixture)
        XCTAssertEqual(graphProbe.factoryCount, 1)
        await store.unloadRoot(id: loaded.id)
    }

    func testCheckoutAndCatalogAdvanceFenceOldAuthorityBeforeSuccessorDemand() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let feature = try XCTUnwrap(loadedFiles.first)
        let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: feature.id))
        let ready = try await readyResult(settledResult(store: store, ticket: ticket))
        let logicalPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Workspace",
            standardizedRelativePath: feature.standardizedRelativePath
        ))
        let presentation = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: ticket, logicalPath: logicalPath)
            ])
        )
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: ticket)
            ])
        )
        let oldGraph = try XCTUnwrap(graphProbe.graph(rootEpoch: ticket.rootEpoch))

        let service = WorkspaceCheckoutRefreshService(
            store: store,
            searchService: WorkspaceSearchService()
        )
        _ = await service.refreshAfterCheckoutMutation(rootPath: root.path)
        await assertStale(store.codemapArtifactDemandStatus(ticket))
        XCTAssertThrowsError(try ready.handle.artifactKey())
        if case .ready = await store.renderCodemapPresentation(presentation) {
            XCTFail("Checkout must revoke the retained presentation before returning.")
        }
        try await assertEngineRootCount(1, fixture: fixture)
        let oldGraphAccounting = await oldGraph.accounting()
        XCTAssertEqual(oldGraphAccounting.activeRebuildCount, 0)

        let successorFileValue = await store.file(
            rootID: loaded.id,
            relativePath: feature.standardizedRelativePath
        )
        let successorFile = try XCTUnwrap(successorFileValue)
        let successorTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: successorFile.id))
        XCTAssertGreaterThan(successorTicket.catalogGeneration, ticket.catalogGeneration)
        let successorResult = try await settledResult(store: store, ticket: successorTicket)
        guard case .ready = successorResult else {
            return XCTFail("Expected checkout successor ready, got \(successorResult).")
        }
        _ = try await store.createFile(
            rootID: loaded.id,
            relativePath: "Sources/CatalogReplacement.swift",
            content: "struct CatalogReplacement {}\n"
        )
        await assertStale(store.codemapArtifactDemandStatus(successorTicket))
        try await assertEngineRootCount(1, fixture: fixture)
        await store.unloadRoot(id: loaded.id)
    }

    func testUnloadAwaitsPresentationGraphAndEngineRevocationBeforeReturning() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let feature = try XCTUnwrap(loadedFiles.first)
        let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: feature.id))
        let ready = try await readyResult(settledResult(store: store, ticket: ticket))
        let logicalPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Workspace",
            standardizedRelativePath: feature.standardizedRelativePath
        ))
        let presentation = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: ticket, logicalPath: logicalPath)
            ])
        )
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: ticket)
            ])
        )
        let graph = try XCTUnwrap(graphProbe.graph(rootEpoch: ticket.rootEpoch))

        await store.unloadRoot(id: loaded.id)
        await assertStale(store.codemapArtifactDemandStatus(ticket))
        XCTAssertThrowsError(try ready.handle.artifactKey())
        if case .ready = await store.renderCodemapPresentation(presentation) {
            XCTFail("Unload must revoke the retained presentation before returning.")
        }
        let graphAccounting = await graph.accounting()
        XCTAssertEqual(graphAccounting.currentUnavailableReason, .explicitRootUnavailable(.rootUnloaded))
        XCTAssertEqual(graphAccounting.activeRebuildCount, 0)
        try await assertEngineRootCount(0, fixture: fixture)
        let route = await fixture.registry.makeBindingCatalogClient().resolveManifestBinding(
            ticket.rootEpoch,
            feature.standardizedRelativePath
        )
        XCTAssertNil(route)
    }

    func testAutomaticSelectionResolvesSameRootTargetsFromCurrentCatalog() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })

        for file in [source, target] {
            let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
            _ = try await readyResult(settledResult(store: store, ticket: ticket))
        }
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let sourceIdentity = try XCTUnwrap(identities.first)
        let providerCount = fixture.providerAccessCount.value
        let buildCount = fixture.buildCount.value
        let manifestReadCount = fixture.manifestReadCount.value

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: identities,
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(result.roots.count, 1)
        XCTAssertEqual(result.targets.map(\.fileID), [target.id])
        XCTAssertEqual(result.targets.first?.rootEpoch, sourceIdentity.rootEpoch)
        XCTAssertEqual(result.targets.first?.catalogGeneration, sourceIdentity.catalogGeneration)
        XCTAssertEqual(result.targets.first?.logicalPath.displayPath, "repository/Sources/Target.swift")
        XCTAssertEqual(
            result.roots.first?.coverage,
            .partial([.graph(.definitionUniverseIncomplete)])
        )
        XCTAssertEqual(fixture.providerAccessCount.value, providerCount)
        XCTAssertEqual(fixture.buildCount.value, buildCount)
        XCTAssertEqual(fixture.manifestReadCount.value, manifestReadCount)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionDoesNotResolveForeignOnlyDefinition() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let firstRoot = try firstRepository.makeRepository(
            named: "first",
            files: [
                "Sources/Source.swift": """
                protocol SourceProtocol {
                    func value() -> ForeignDefinition
                }
                """
            ]
        )
        let secondRoot = try secondRepository.makeRepository(
            named: "second",
            files: [
                "Sources/ForeignDefinition.swift": "struct ForeignDefinition {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        addTeardownBlock {
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let store = fixture.makeStore()
        let firstLoaded = try await store.loadRoot(path: firstRoot.path)
        let secondLoaded = try await store.loadRoot(path: secondRoot.path)
        let firstFiles = await store.files(inRoot: firstLoaded.id)
        let secondFiles = await store.files(inRoot: secondLoaded.id)
        let firstFile = try XCTUnwrap(firstFiles.first)
        let secondFile = try XCTUnwrap(secondFiles.first)
        for file in [firstFile, secondFile] {
            let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
            _ = try await readyResult(settledResult(store: store, ticket: ticket))
        }
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [firstFile.id],
            rootScope: .visibleWorkspace
        )

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: identities,
            rootScope: .visibleWorkspace
        )

        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertFalse(result.targets.contains { $0.fileID == secondFile.id })
        XCTAssertEqual(result.roots.first?.rootEpoch.rootID, firstLoaded.id)
        await store.unloadRoot(id: firstLoaded.id)
        await store.unloadRoot(id: secondLoaded.id)
    }

    func testAutomaticSelectionQueriesTwoRootsIndependentlyAndMergesAtResponseBoundary() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let firstRoot = try firstRepository.makeRepository(
            named: "first",
            files: [
                "Sources/Source.swift": """
                protocol FirstSource {
                    func value() -> FirstTarget
                }
                """,
                "Sources/Target.swift": "struct FirstTarget {}\n"
            ]
        )
        let secondRoot = try secondRepository.makeRepository(
            named: "second",
            files: [
                "Sources/Source.swift": """
                protocol SecondSource {
                    func value() -> SecondTarget
                }
                """,
                "Sources/Target.swift": "struct SecondTarget {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        var loadedRoots: [WorkspaceRootRecord] = []
        var sourceIDs: [UUID] = []
        var targetIDs = Set<UUID>()
        for root in [firstRoot, secondRoot] {
            let loaded = try await store.loadRoot(path: root.path)
            loadedRoots.append(loaded)
            let files = await store.files(inRoot: loaded.id)
            let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
            let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
            sourceIDs.append(source.id)
            targetIDs.insert(target.id)
            for file in [source, target] {
                let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
                _ = try await readyResult(settledResult(store: store, ticket: ticket))
            }
        }
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: Array(sourceIDs.reversed()),
            rootScope: .visibleWorkspace
        )

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: identities,
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(result.roots.count, 2)
        XCTAssertEqual(Set(result.targets.map(\.fileID)), targetIDs)
        XCTAssertEqual(Set(result.roots.map(\.rootEpoch.rootID)), Set(loadedRoots.map(\.id)))
        for rootResult in result.roots {
            XCTAssertTrue(rootResult.targets.allSatisfy { $0.rootEpoch == rootResult.rootEpoch })
        }
        XCTAssertEqual(graphProbe.factoryCount, 2)
        for loaded in loadedRoots {
            await store.unloadRoot(id: loaded.id)
        }
    }

    func testAutomaticSelectionReportsMissingPendingUnavailableAndStaleSourcesWithoutNewWork() async throws {
        let resolutionGate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(name: #function, resolutionGate: resolutionGate)
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Pending.swift": "struct Pending {}\n"]
        )
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await resolutionGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [file.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)
        let pending = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
        let resolutionEntered = await resolutionGate.waitUntilEntered()
        XCTAssertTrue(resolutionEntered)
        let missing = try WorkspaceCodemapAutomaticSelectionSourceIdentity(
            rootEpoch: identity.rootEpoch,
            fileID: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000000")),
            catalogGeneration: identity.catalogGeneration
        )
        let stale = WorkspaceCodemapAutomaticSelectionSourceIdentity(
            rootEpoch: identity.rootEpoch,
            fileID: file.id,
            catalogGeneration: identity.catalogGeneration &+ 1
        )
        let providerCount = fixture.providerAccessCount.value

        let expectedIssues: [WorkspaceCodemapAutomaticSelectionSourceIssue] = [
            .notCataloged(missing),
            .pending(identity, pending),
            .staleCatalogGeneration(
                stale,
                currentCatalogGeneration: identity.catalogGeneration
            )
        ]
        let firstResult = try await store.resolveAutomaticCodemapSelection(
            sources: [identity, missing, stale],
            rootScope: .visibleWorkspace
        )
        let secondResult = try await store.resolveAutomaticCodemapSelection(
            sources: [stale, identity, missing],
            rootScope: .visibleWorkspace
        )

        let expectedCoverage = WorkspaceCodemapAutomaticSelectionCoverage.stale(
            .sourceCatalogGeneration(
                stale,
                currentCatalogGeneration: identity.catalogGeneration
            )
        )
        XCTAssertEqual(firstResult.roots.first?.sourceIssues, expectedIssues)
        XCTAssertEqual(secondResult.roots.first?.sourceIssues, expectedIssues)
        XCTAssertEqual(firstResult.roots.first?.coverage, expectedCoverage)
        XCTAssertEqual(secondResult.roots.first?.coverage, expectedCoverage)
        XCTAssertEqual(fixture.providerAccessCount.value, providerCount)
        XCTAssertEqual(graphProbe.factoryCount, 0)
        await resolutionGate.release()
        _ = try await settledResult(store: store, ticket: pending)

        let plainRoot = try fixture.makePlainRoot(files: [
            "Sources/Unavailable.swift": "struct Unavailable {}\n"
        ])
        let plainLoaded = try await store.loadRoot(path: plainRoot.path)
        let plainFiles = await store.files(inRoot: plainLoaded.id)
        let plainFile = try XCTUnwrap(plainFiles.first)
        let plainIdentities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [plainFile.id],
            rootScope: .visibleWorkspace
        )
        let plainIdentity = try XCTUnwrap(plainIdentities.first)
        let plainTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: plainFile.id))
        let unavailable = try await settledResult(store: store, ticket: plainTicket)
        guard case let .unavailable(unavailableReason) = unavailable else {
            return XCTFail("Expected non-Git demand to become unavailable.")
        }
        let unavailableResult = try await store.resolveAutomaticCodemapSelection(
            sources: [plainIdentity],
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(
            unavailableResult.roots.first?.sourceIssues,
            [.unavailable(plainIdentity, unavailableReason)]
        )
        await store.unloadRoot(id: loaded.id)
        await store.unloadRoot(id: plainLoaded.id)
    }

    func testAutomaticSelectionRejectsSourceOutsideRequestedRootScopeBeforeGraphQuery() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let firstRoot = try firstRepository.makeRepository(
            named: "first",
            files: ["Sources/First.swift": "struct First {}\n"]
        )
        let secondRoot = try secondRepository.makeRepository(
            named: "second",
            files: ["Sources/Second.swift": "struct Second {}\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let firstLoaded = try await store.loadRoot(path: firstRoot.path)
        let secondLoaded = try await store.loadRoot(path: secondRoot.path)
        let firstFiles = await store.files(inRoot: firstLoaded.id)
        let firstFile = try XCTUnwrap(firstFiles.first)
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [firstFile.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)
        let secondOnlyScope = WorkspaceLookupRootScope.sessionBoundWorkspace(
            canonicalRootPaths: [secondRoot.path],
            physicalRootPaths: []
        )

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: [identity],
            rootScope: secondOnlyScope
        )

        XCTAssertEqual(result.targets, [])
        XCTAssertEqual(result.roots.first?.sourceIssues, [.outsideRootScope(identity)])
        XCTAssertEqual(result.roots.first?.coverage, .unavailable(.noReadySources))
        XCTAssertEqual(graphProbe.factoryCount, 0)
        await store.unloadRoot(id: firstLoaded.id)
        await store.unloadRoot(id: secondLoaded.id)
    }

    func testAutomaticSelectionRootReloadDropsOldTargets() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": """
                protocol SourceProtocol {
                    func target() -> Target
                }
                """,
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        for file in files {
            let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
            _ = try await readyResult(settledResult(store: store, ticket: ticket))
        }
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)
        let beforeReload = try await store.resolveAutomaticCodemapSelection(
            sources: [identity],
            rootScope: .visibleWorkspace
        )
        XCTAssertFalse(beforeReload.targets.isEmpty)

        await store.unloadRoot(id: loaded.id)
        let reloaded = try await store.loadRoot(path: root.path)
        let afterReload = try await store.resolveAutomaticCodemapSelection(
            sources: [identity],
            rootScope: .visibleWorkspace
        )

        XCTAssertTrue(afterReload.targets.isEmpty)
        XCTAssertEqual(afterReload.roots.first?.coverage, .stale(.rootEpochNotCurrent(identity.rootEpoch)))
        await store.unloadRoot(id: reloaded.id)
    }

    func testAutomaticSelectionOmitsTargetWhoseGenerationBecomesStale() async throws {
        let queryGate = CodemapArmableSuspensionGate()
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": """
                protocol SourceProtocol {
                    func target() -> Target
                }
                """,
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        addTeardownBlock {
            await queryGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(automaticSelectionQueryHook: { _ in
            await queryGate.enterIfArmedAndWait()
        })
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        var targetTicket: WorkspaceCodemapArtifactDemandTicket?
        for file in [source, target] {
            let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
            _ = try await readyResult(settledResult(store: store, ticket: ticket))
            if file.id == target.id { targetTicket = ticket }
        }
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)
        let current = try await store.resolveAutomaticCodemapSelection(
            sources: [identity],
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(current.targets.map(\.fileID), [target.id])
        await queryGate.arm()
        let task = Task {
            try await store.resolveAutomaticCodemapSelection(
                sources: [identity],
                rootScope: .visibleWorkspace
            )
        }
        let queryEntered = await queryGate.waitUntilEntered()
        XCTAssertTrue(queryEntered)
        let unwrappedTargetTicket = try XCTUnwrap(targetTicket)
        let targetCancelled = await store.cancelCodemapArtifactDemand(unwrappedTargetTicket)
        XCTAssertTrue(targetCancelled)
        await queryGate.release()
        let result = try await task.value

        XCTAssertTrue(result.targets.isEmpty)
        guard case let .staleGeneration(rootEpoch, fileID, _) = result.roots.first?.targetIssues.first else {
            return XCTFail("Expected the stale target generation to be reported: \(result)")
        }
        XCTAssertEqual(rootEpoch, identity.rootEpoch)
        XCTAssertEqual(fileID, target.id)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionDropsResultWhenSourceChangesAfterGraphQuery() async throws {
        let queryGate = CodemapArmableSuspensionGate()
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        addTeardownBlock {
            await queryGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(automaticSelectionQueryHook: { _ in
            await queryGate.enterIfArmedAndWait()
        })
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        var sourceTicket: WorkspaceCodemapArtifactDemandTicket?
        for file in files {
            let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
            _ = try await readyResult(settledResult(store: store, ticket: ticket))
            if file.id == source.id { sourceTicket = ticket }
        }
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)
        await queryGate.arm()
        let task = Task {
            try await store.resolveAutomaticCodemapSelection(
                sources: [identity],
                rootScope: .visibleWorkspace
            )
        }
        let queryEntered = await queryGate.waitUntilEntered()
        XCTAssertTrue(queryEntered)
        let ticket = try XCTUnwrap(sourceTicket)
        let cancelled = await store.cancelCodemapArtifactDemand(ticket)
        XCTAssertTrue(cancelled)
        await queryGate.release()
        let result = try await task.value

        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertEqual(
            result.roots.first?.coverage,
            .stale(.graph(.currentness(identity.rootEpoch)))
        )
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionRetriesWhenPendingSourceBecomesReadyDuringGraphAwait() async throws {
        let pendingPublicationGate = CodemapArmableSuspensionGate()
        let queryGate = CodemapArmableSuspensionGate()
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Ready.swift": "struct Ready { let missing: Missing }\n",
                "Sources/Pending.swift": "struct Pending {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await pendingPublicationGate.release()
            await queryGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            readyPublicationHook: { _ in
                await pendingPublicationGate.enterIfArmedAndWait()
            },
            automaticSelectionQueryHook: { _ in
                await queryGate.enterIfArmedAndWait()
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let readyFile = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Ready.swift"
        })
        let pendingFile = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Pending.swift"
        })
        let readyTicket = try await pendingTicket(store.requestCodemapArtifact(
            forFileID: readyFile.id
        ))
        _ = try await readyResult(settledResult(store: store, ticket: readyTicket))
        let graphPublished = await graphProbe.waitUntilPublished(rootEpoch: readyTicket.rootEpoch)
        XCTAssertTrue(graphPublished)

        await pendingPublicationGate.arm()
        let pendingTicket = try await pendingTicket(store.requestCodemapArtifact(
            forFileID: pendingFile.id
        ))
        let publicationEntered = await pendingPublicationGate.waitUntilEntered()
        XCTAssertTrue(publicationEntered)
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [readyFile.id, pendingFile.id],
            rootScope: .visibleWorkspace
        )
        await queryGate.arm()
        let task = Task {
            try await store.resolveAutomaticCodemapSelection(
                sources: identities,
                rootScope: .visibleWorkspace
            )
        }
        let queryEntered = await queryGate.waitUntilEntered()
        XCTAssertTrue(queryEntered)

        await pendingPublicationGate.release()
        _ = try await readyResult(settledResult(store: store, ticket: pendingTicket))
        await queryGate.release()
        let result = try await task.value

        XCTAssertFalse(result.roots.flatMap(\.sourceIssues).contains {
            if case .pending = $0 { return true }
            return false
        })
        XCTAssertFalse(result.roots.contains {
            if case .stale(.sourceStateChanged(_)) = $0.coverage { return true }
            return false
        })
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionResnapshotsScopeChangeBetweenRootPartitions() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let firstRoot = try firstRepository.makeRepository(
            named: "first",
            files: ["Sources/Source.swift": "struct First { let missing: Missing }\n"]
        )
        let secondRoot = try secondRepository.makeRepository(
            named: "second",
            files: ["Sources/Source.swift": "struct Second { let missing: Missing }\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let queryGate = CodemapRootSuspensionGate()
        addTeardownBlock {
            await queryGate.release()
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let store = fixture.makeStore(automaticSelectionQueryHook: { rootEpoch in
            await queryGate.enterAndWait(rootEpoch)
        })
        var loadedRoots: [WorkspaceRootRecord] = []
        var fileIDs: [UUID] = []
        for root in [firstRoot, secondRoot] {
            let loaded = try await store.loadRoot(path: root.path)
            loadedRoots.append(loaded)
            let files = await store.files(inRoot: loaded.id)
            let file = try XCTUnwrap(files.first)
            fileIDs.append(file.id)
            let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
            _ = try await readyResult(settledResult(store: store, ticket: ticket))
        }
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: fileIDs,
            rootScope: .visibleWorkspace
        )
        let task = Task {
            try await store.resolveAutomaticCodemapSelection(
                sources: identities,
                rootScope: .visibleWorkspace
            )
        }
        let entered = await queryGate.waitUntilEntered()
        let enteredRootEpoch = try XCTUnwrap(entered)
        let removedRoot = try XCTUnwrap(loadedRoots.first {
            $0.id != enteredRootEpoch.rootID
        })
        await store.unloadRoot(id: removedRoot.id)
        await queryGate.release()
        let result = try await task.value

        let removedResult = try XCTUnwrap(result.roots.first {
            $0.rootEpoch.rootID == removedRoot.id
        })
        XCTAssertEqual(
            removedResult.coverage,
            .stale(.rootEpochNotCurrent(removedResult.rootEpoch))
        )
        XCTAssertTrue(removedResult.targets.isEmpty)
        for loaded in loadedRoots where loaded.id != removedRoot.id {
            await store.unloadRoot(id: loaded.id)
        }
    }

    func testAutomaticSelectionLaterRootBudgetDiscardsEarlierTargetsAndReceipt() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let firstRootURL = try firstRepository.makeRepository(
            named: "first",
            files: [
                "Sources/Source.swift": "protocol FirstSource { var target: FirstTarget { get } }\n",
                "Sources/Target.swift": "struct FirstTarget {}\n"
            ]
        )
        let secondRootURL = try secondRepository.makeRepository(
            named: "second",
            files: [
                "Sources/Source.swift": "protocol SecondSource { var target: SecondTarget { get } }\n",
                "Sources/Target.swift": "struct SecondTarget {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let store = fixture.makeStore(selectionGraphQueryBudgetPolicy: .init(
            maximumTargetCount: 1,
            maximumResolutionCount: 100,
            maximumReferenceFailureCount: 100
        ))
        var loadedRoots: [WorkspaceRootRecord] = []
        var sourceIDs: [UUID] = []
        for rootURL in [firstRootURL, secondRootURL] {
            let loaded = try await store.loadRoot(path: rootURL.path)
            loadedRoots.append(loaded)
            let files = await store.files(inRoot: loaded.id)
            for file in files {
                let ticket = try await pendingTicket(
                    store.requestCodemapArtifact(forFileID: file.id)
                )
                _ = try await readyResult(settledResult(store: store, ticket: ticket))
            }
            try sourceIDs.append(XCTUnwrap(files.first {
                $0.standardizedRelativePath == "Sources/Source.swift"
            }).id)
        }
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: sourceIDs,
            rootScope: .visibleWorkspace
        )

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: identities,
            rootScope: .visibleWorkspace
        )

        XCTAssertTrue(result.roots.isEmpty)
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        guard case let .budget(reason) = result.aggregateCoverage else {
            return XCTFail("Expected aggregate target budget")
        }
        XCTAssertEqual(reason, .targetLimit(attempted: 2, limit: 1))
        for root in loadedRoots {
            await store.unloadRoot(id: root.id)
        }
    }

    func testAutomaticSelectionReturnsTypedBudgetAndBusyCoverage() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": """
                protocol SourceProtocol {
                    func first() -> FirstTarget
                    func second() -> SecondTarget
                }
                """,
                "Sources/First.swift": "struct FirstTarget {}\n",
                "Sources/Second.swift": "struct SecondTarget {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let budgetStore = fixture.makeStore(selectionGraphQueryBudgetPolicy: .init(
            maximumTargetCount: 1,
            maximumResolutionCount: 100,
            maximumReferenceFailureCount: 100
        ))
        let loaded = try await budgetStore.loadRoot(path: root.path)
        let files = await budgetStore.files(inRoot: loaded.id)
        for file in files {
            let ticket = try await pendingTicket(budgetStore.requestCodemapArtifact(forFileID: file.id))
            _ = try await readyResult(settledResult(store: budgetStore, ticket: ticket))
        }
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let identities = await budgetStore.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)
        let budgetResult = try await budgetStore.resolveAutomaticCodemapSelection(
            sources: [identity],
            rootScope: .visibleWorkspace
        )
        XCTAssertTrue(budgetResult.roots.isEmpty)
        XCTAssertTrue(budgetResult.targets.isEmpty)
        XCTAssertNil(budgetResult.publicationReceipt)
        XCTAssertEqual(
            budgetResult.aggregateCoverage,
            .budget(.targetLimit(attempted: 2, limit: 1))
        )
        await budgetStore.unloadRoot(id: loaded.id)

        let buildGate = CodemapSelectionGraphBuildGate()
        let busyFixture = try CodemapStoreFixture(
            name: #function + "-busy",
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe(buildGate: buildGate)
        addTeardownBlock {
            buildGate.releaseAll()
            await busyFixture.shutdown()
        }
        let busyStore = busyFixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let busyLoaded = try await busyStore.loadRoot(path: root.path)
        let busyFiles = await busyStore.files(inRoot: busyLoaded.id)
        let busySource = try XCTUnwrap(busyFiles.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let busyTicket = try await pendingTicket(busyStore.requestCodemapArtifact(forFileID: busySource.id))
        _ = try await readyResult(settledResult(store: busyStore, ticket: busyTicket))
        XCTAssertNotNil(buildGate.waitUntilFirstBlocked())
        let busyIdentities = await busyStore.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [busySource.id],
            rootScope: .visibleWorkspace
        )
        let busyIdentity = try XCTUnwrap(busyIdentities.first)
        let busyResult = try await busyStore.resolveAutomaticCodemapSelection(
            sources: [busyIdentity],
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(
            busyResult.roots.first?.coverage,
            .busy(.runtime(rootEpoch: busyIdentity.rootEpoch, reason: .rebuilding))
        )
        buildGate.releaseAll()
        await busyStore.unloadRoot(id: busyLoaded.id)
    }

    func testAutomaticSelectionAccountingOverflowFailsClosedWithoutReceipt() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": """
                protocol SourceProtocol {
                    func first() -> FirstTarget
                    func second() -> SecondTarget
                }
                """,
                "Sources/First.swift": "struct FirstTarget {}\n",
                "Sources/Second.swift": "struct SecondTarget {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphQueryBudgetPolicy: .init(
                maximumTargetCount: 1,
                maximumResolutionCount: 100,
                maximumReferenceFailureCount: 100
            ),
            automaticSelectionAccountingMaximum: 1
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        for file in files {
            let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
            _ = try await readyResult(settledResult(store: store, ticket: ticket))
        }
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: identities,
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(result.roots, [])
        XCTAssertEqual(result.targets, [])
        XCTAssertNil(result.publicationReceipt)
        XCTAssertEqual(result.aggregateCoverage, .budget(.accountingOverflow))
        await store.unloadRoot(id: loaded.id)
    }

    @MainActor
    func testAutomaticSelectionTimeoutRetainsProjectionAndReadinessRetryRecovers() async throws {
        let publicationGate = CodemapArmableSuspensionGate()
        let publishedTickets = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await publicationGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            readyPublicationHook: { ticket in
                publishedTickets.append(ticket)
                await publicationGate.enterIfArmedAndWait()
            }
        )
        let manager = WorkspaceFilesViewModel(
            workspaceFileContextStore: store,
            automaticCodemapSelectionRequestPolicy: .init(
                maximumReadinessRounds: 1,
                initialBackoffMilliseconds: 1,
                maximumBackoffMilliseconds: 1,
                maximumTotalWait: .milliseconds(1)
            ),
            automaticCodemapSelectionWaiter: .init { _ in }
        )
        addTeardownBlock { @MainActor in
            await manager.unloadAllRootFolders()
        }
        let workspace = WorkspaceModel(name: #function, repoPaths: [root.path])
        try await manager.loadFolder(at: root, for: workspace)
        let materializedSource = await manager.materializeFileForUserInput(
            root.appendingPathComponent("Sources/Source.swift").path,
            profile: .mcpRead
        )
        let source = try XCTUnwrap(materializedSource)
        let materializedTarget = await manager.materializeFileForUserInput(
            root.appendingPathComponent("Sources/Target.swift").path,
            profile: .mcpRead
        )
        let target = try XCTUnwrap(materializedTarget)

        let targetTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: target.id))
        _ = try await readyResult(settledResult(store: store, ticket: targetTicket))
        let targetGraphPublished = await graphProbe.waitUntilPublished(rootEpoch: targetTicket.rootEpoch)
        XCTAssertTrue(targetGraphPublished)

        manager.selectFileForTesting(source)
        manager.setAutoCodemapFilesForTesting([target])
        await publicationGate.arm()
        await manager.flushAutoCodemapSyncNowIfNeeded()
        XCTAssertEqual(manager.autoCodemapFiles.map(\.id), [target.id])

        let publicationEntered = await publicationGate.waitUntilEntered()
        XCTAssertTrue(publicationEntered)
        let sourceTicket = try XCTUnwrap(publishedTickets.values.last)
        await publicationGate.release()
        _ = try await readyResult(settledResult(store: store, ticket: sourceTicket))
        let sourceGraphPublished = await graphProbe.waitUntilPublished(rootEpoch: sourceTicket.rootEpoch)
        XCTAssertTrue(sourceGraphPublished)

        manager.handleAutomaticCodemapReadinessForTesting(
            rootEpoch: sourceTicket.rootEpoch
        )
        await manager.waitForAutoCodemapSyncForTesting()
        XCTAssertEqual(manager.autoCodemapFiles.map(\.id), [target.id])
        await manager.unloadAllRootFolders()
    }

    func testAutomaticSelectionGraphAdmissionReleaseEmitsReadinessAndRetrySucceeds() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let blockerRoot = try repositoryFixture.makeRepository(
            named: "blocker",
            files: ["Sources/Blocker.swift": "struct Blocker {}\n"]
        )
        let selectionRoot = try repositoryFixture.makeRepository(
            named: "selection",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let buildGate = CodemapSelectionGraphBuildGate()
        let graphProbe = CodemapSelectionGraphProbe(
            buildGate: buildGate,
            admissionPolicy: .init(
                maximumActiveReservationCount: 1,
                maximumReservedBindingCount: 100_000
            )
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        addTeardownBlock {
            buildGate.releaseAll()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let blocker = try await store.loadRoot(path: blockerRoot.path)
        let selection = try await store.loadRoot(path: selectionRoot.path)
        let blockerFiles = await store.files(inRoot: blocker.id)
        let blockerFile = try XCTUnwrap(blockerFiles.first)
        let blockerTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: blockerFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: blockerTicket))
        let blockerGeneration = try XCTUnwrap(buildGate.waitUntilFirstBlocked())

        let selectionFiles = await store.files(inRoot: selection.id)
        let source = try XCTUnwrap(selectionFiles.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let target = try XCTUnwrap(selectionFiles.first {
            $0.standardizedRelativePath == "Sources/Target.swift"
        })
        for file in [source, target] {
            let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
            _ = try await readyResult(settledResult(store: store, ticket: ticket))
        }

        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(
                maximumReadinessRounds: 1,
                initialBackoffMilliseconds: 1,
                maximumBackoffMilliseconds: 1,
                maximumTotalWait: .milliseconds(1)
            ),
            automaticSelectionWaiter: .init { _ in }
        )
        let initial = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        guard case .busy = initial.aggregateCoverage else {
            return XCTFail("Expected graph admission to report busy")
        }

        let updates = await store.codemapSelectionGraphReadinessUpdates()
        let readiness = Task {
            for await event in updates where event.rootEpoch.rootID == selection.id {
                return true
            }
            return false
        }
        buildGate.release(generation: blockerGeneration)
        let readinessObserved = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await readiness.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let observed = await group.next() ?? false
            group.cancelAll()
            readiness.cancel()
            return observed
        }
        XCTAssertTrue(readinessObserved)
        XCTAssertNotNil(buildGate.waitUntilBlocked(after: blockerGeneration))
        buildGate.releaseAll()

        let retried = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        switch retried.aggregateCoverage {
        case .complete, .partial:
            XCTAssertNotNil(retried.publicationReceipt)
        case .pending, .unavailable, .stale, .busy, .budget:
            XCTFail("Expected readiness-triggered retry to succeed")
        }
        await store.unloadRoot(id: selection.id)
        await store.unloadRoot(id: blocker.id)
    }

    func testAutomaticSelectionWithoutExistingDemandPerformsNoIOOrArtifactWork() async throws {
        let fixture = try CodemapStoreFixture(name: #function)
        let root = try fixture.makePlainRoot(files: [
            "Sources/Source.swift": "struct Source {}\n"
        ])
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock { await fixture.shutdown() }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [file.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: [identity],
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(result.roots.first?.sourceIssues, [.notDemanded(identity)])
        XCTAssertEqual(result.roots.first?.coverage, .unavailable(.noReadySources))
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 0)
        XCTAssertEqual(fixture.engineFactoryCount.value, 0)
        XCTAssertEqual(fixture.manifestReadCount.value, 0)
        XCTAssertEqual(fixture.buildCount.value, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionRetriesBusySourceTwiceThenBecomesReady() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Setup.swift": "struct Setup {}\n",
                "Sources/Source.swift": "struct Source {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        let demandInvocations = CodemapLockedCounter()
        let waits = CodemapLockedCounter()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(demandResultHook: { _, result in
            demandInvocations.increment()
            if demandInvocations.value == 3 || demandInvocations.value == 4 {
                return .busy(retryAfterMilliseconds: 1)
            }
            return result
        })
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let setup = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Setup.swift"
        })
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let setupTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: setup.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: setupTicket))
        let warmSourceTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: source.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: warmSourceTicket))
        _ = await store.cancelCodemapArtifactDemand(warmSourceTicket)
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(
                maximumReadinessRounds: 6,
                initialBackoffMilliseconds: 400,
                maximumBackoffMilliseconds: 400,
                maximumTotalWait: .seconds(2)
            ),
            automaticSelectionWaiter: .init { duration in
                waits.increment()
                try await Task.sleep(for: duration)
            }
        )

        let result = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(demandInvocations.value, 5)
        XCTAssertGreaterThanOrEqual(waits.value, 2)
        XCTAssertNotNil(result.publicationReceipt)
        switch result.aggregateCoverage {
        case .complete, .partial:
            break
        case .pending, .unavailable, .stale, .busy, .budget:
            XCTFail("Expected publishable coverage after busy retries")
        }
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionBusySourceExhaustionStopsAtConfiguredBounds() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Setup.swift": "struct Setup {}\n",
                "Sources/Source.swift": "struct Source {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        let demandInvocations = CodemapLockedCounter()
        let waits = CodemapLockedCounter()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(demandResultHook: { _, result in
            demandInvocations.increment()
            if demandInvocations.value <= 2 { return result }
            return .busy(retryAfterMilliseconds: 1)
        })
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let setup = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Setup.swift"
        })
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let setupTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: setup.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: setupTicket))
        let warmSourceTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: source.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: warmSourceTicket))
        _ = await store.cancelCodemapArtifactDemand(warmSourceTicket)
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(
                maximumReadinessRounds: 6,
                initialBackoffMilliseconds: 400,
                maximumBackoffMilliseconds: 400,
                maximumTotalWait: .seconds(2)
            ),
            automaticSelectionWaiter: .init { duration in
                waits.increment()
                try await Task.sleep(for: duration)
            }
        )

        let result = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )

        let sourceDemandInvocations = demandInvocations.value - 2
        XCTAssertGreaterThanOrEqual(sourceDemandInvocations, 1)
        XCTAssertLessThanOrEqual(sourceDemandInvocations, 6)
        XCTAssertLessThanOrEqual(waits.value, 5)
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        guard case let .pending(reasons) = result.aggregateCoverage else {
            return XCTFail("Expected bounded busy pending coverage")
        }
        XCTAssertEqual(reasons.count, 1)
        if case let .sourceBusy(_, attempts) = reasons[0] {
            XCTAssertEqual(sourceDemandInvocations, attempts + 1)
        } else {
            XCTFail("Expected source busy reason")
        }
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionSourceDemandLimitAllowsNAndRejectsNPlusOneBeforeFanout() async throws {
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        let root = try fixture.makePlainRoot(files: [
            "Sources/First.swift": "struct First {}\n",
            "Sources/Second.swift": "struct Second {}\n",
            "Sources/Third.swift": "struct Third {}\n"
        ])
        addTeardownBlock { await fixture.shutdown() }
        let store = fixture.makeStore(selectionGraphQueryBudgetPolicy: .init(
            maximumRawSourceCount: 2,
            maximumUniqueSourceCount: 2,
            maximumTargetCount: 100,
            maximumResolutionCount: 100,
            maximumReferenceFailureCount: 100
        ))
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id).sorted {
            $0.standardizedRelativePath < $1.standardizedRelativePath
        }
        let demandCount = CodemapLockedCounter()
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionSourceDemandHook: { _, _ in demandCount.increment() }
        )

        _ = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: Array(files.prefix(2).map(\.id)),
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(demandCount.value, 2)

        let rejected = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: files.map(\.id),
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(demandCount.value, 2)
        XCTAssertEqual(rejected.targets, [])
        XCTAssertNil(rejected.publicationReceipt)
        XCTAssertEqual(rejected.aggregateCoverage, .budget(.sourceLimit(attempted: 3, limit: 2)))
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionCancellationMidSourceFanoutCancelsOnlyIssuedTickets() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/First.swift": "struct First {}\n",
                "Sources/Second.swift": "struct Second {}\n"
            ]
        )
        let gate = CodemapSuspensionGate()
        addTeardownBlock {
            await gate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let cancelledTickets = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        let store = fixture.makeStore(cancellationCleanupHook: { ticket in
            cancelledTickets.append(ticket)
        })
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id).sorted {
            $0.standardizedRelativePath < $1.standardizedRelativePath
        }
        let demandCount = CodemapLockedCounter()
        let issuedTickets = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionSourceDemandHook: { _, result in
                demandCount.increment()
                if case let .pending(ticket) = result {
                    issuedTickets.append(ticket)
                } else if case let .ready(ready) = result {
                    issuedTickets.append(ready.ticket)
                }
                if demandCount.value == 1 {
                    await gate.enterAndWait()
                }
            }
        )
        let task = Task {
            try await service.resolveAutomaticCodemapSelection(
                sourceFileIDs: files.map(\.id),
                rootScope: .visibleWorkspace
            )
        }
        let fanoutEntered = await gate.waitUntilEntered()
        XCTAssertTrue(fanoutEntered)
        let selectionTicket = try XCTUnwrap(issuedTickets.values.first)
        let joinedResult = await store.requestCodemapArtifact(forFileID: files[0].id)
        let joinedTicket: WorkspaceCodemapArtifactDemandTicket
        switch joinedResult {
        case let .pending(ticket):
            joinedTicket = ticket
        case let .ready(ready):
            joinedTicket = ready.ticket
        case let .unavailable(reason):
            return XCTFail("Expected joined demand, got \(reason)")
        }
        XCTAssertNotEqual(selectionTicket.retainID, joinedTicket.retainID)
        let joinedRetainCount = await store.codemapArtifactDemandRetainCountForTesting(selectionTicket)
        XCTAssertEqual(joinedRetainCount, 2)
        task.cancel()
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(demandCount.value, 1)
        XCTAssertEqual(issuedTickets.values.count, 1)
        let survivingRetainCount = await store.codemapArtifactDemandRetainCountForTesting(joinedTicket)
        XCTAssertEqual(survivingRetainCount, 1)
        XCTAssertTrue(cancelledTickets.values.isEmpty)
        _ = try await readyResult(settledResult(store: store, ticket: joinedTicket))

        let released = await store.cancelCodemapArtifactDemand(joinedTicket)
        XCTAssertTrue(released)
        let finalRetainCount = await store.codemapArtifactDemandRetainCountForTesting(joinedTicket)
        XCTAssertEqual(finalRetainCount, 0)
        XCTAssertEqual(cancelledTickets.values, [joinedTicket])
        let releasedStatus = await store.codemapArtifactDemandStatus(joinedTicket)
        guard case .unavailable(.staleCurrentness) = releasedStatus else {
            return XCTFail("Expected the released caller token to become stale")
        }
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionMissingManifestEnvelopesIsPartialWithoutUnrelatedBuilds() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": "struct Target {}\n",
                "Sources/Unrelated.swift": "struct Unrelated {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })

        let result = try await WorkspaceSelectionMutationService(store: store)
            .resolveAutomaticCodemapSelection(
                sourceFileIDs: [source.id],
                rootScope: .visibleWorkspace
            )

        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertEqual(fixture.buildCount.value, 1)
        guard case let .partial(reasons) = result.aggregateCoverage else {
            return XCTFail("Expected partial missing-envelope coverage")
        }
        XCTAssertTrue(reasons.contains {
            if case let .candidateUniverseIncomplete(rootEpoch, count) = $0 {
                return rootEpoch.rootID == loaded.id && count == 2
            }
            return false
        })
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionCandidateUniverseBudgetStartsNoTargetDemand() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": "struct Target {}\n",
                "Sources/Unrelated.swift": "struct Unrelated {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(
                maximumReadinessRounds: 6,
                initialBackoffMilliseconds: 50,
                maximumBackoffMilliseconds: 400,
                maximumTotalWait: .seconds(2),
                maximumCandidateCountPerRoot: 1,
                maximumCandidateDemandCount: 1024
            )
        )

        let result = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(
            result.aggregateCoverage,
            .budget(.candidateUniverseLimit(attempted: 2, limit: 1))
        )
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        XCTAssertEqual(fixture.buildCount.value, 1)
        await store.unloadRoot(id: loaded.id)
    }

    func testColdAutomaticSelectionNeverPlansSameNamedDefinitionFromAnotherRoot() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let firstRootURL = try firstRepository.makeRepository(
            named: "first",
            files: ["Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n"]
        )
        let secondRootURL = try secondRepository.makeRepository(
            named: "second",
            files: ["Sources/Target.swift": "struct Target {}\n"]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let warmStore = fixture.makeStore()
        var warmRoots: [WorkspaceRootRecord] = []
        for rootURL in [firstRootURL, secondRootURL] {
            let loaded = try await warmStore.loadRoot(path: rootURL.path)
            warmRoots.append(loaded)
            for file in await warmStore.files(inRoot: loaded.id) {
                let ticket = try await pendingTicket(
                    warmStore.requestCodemapArtifact(forFileID: file.id)
                )
                _ = try await readyResult(settledResult(store: warmStore, ticket: ticket))
            }
        }
        for root in warmRoots {
            await warmStore.unloadRoot(id: root.id)
        }

        let coldStore = fixture.makeStore()
        let firstColdRoot = try await coldStore.loadRoot(path: firstRootURL.path)
        let secondColdRoot = try await coldStore.loadRoot(path: secondRootURL.path)
        let firstFiles = await coldStore.files(inRoot: firstColdRoot.id)
        let source = try XCTUnwrap(firstFiles.first)
        let result = try await WorkspaceSelectionMutationService(store: coldStore)
            .resolveAutomaticCodemapSelection(
                sourceFileIDs: [source.id],
                rootScope: .visibleWorkspace
            )

        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertFalse(result.roots.contains { $0.rootEpoch.rootID == secondColdRoot.id })
        await coldStore.unloadRoot(id: firstColdRoot.id)
        await coldStore.unloadRoot(id: secondColdRoot.id)
    }

    func testColdAutomaticSelectionBuildsOnlyMatchedMissingCASTargetAtBackgroundPriority() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": "struct Target {}\n",
                "Sources/Unrelated.swift": "struct Unrelated {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }

        let warmStore = fixture.makeStore()
        let warmRoot = try await warmStore.loadRoot(path: root.path)
        let warmFiles = await warmStore.files(inRoot: warmRoot.id)
        var targetKey: CodeMapArtifactKey?
        for file in warmFiles {
            let ticket = try await pendingTicket(
                warmStore.requestCodemapArtifact(forFileID: file.id)
            )
            let ready = try await readyResult(settledResult(store: warmStore, ticket: ticket))
            if file.standardizedRelativePath == "Sources/Target.swift" {
                targetKey = ready.snapshot.artifactKey
            }
        }
        let warmBuildCount = fixture.buildCount.value
        await warmStore.unloadRoot(id: warmRoot.id)
        try FileManager.default.removeItem(at: fixture.artifactURL(for: XCTUnwrap(targetKey)))

        let coldStore = try fixture.makeFreshStore()
        let coldRoot = try await coldStore.loadRoot(path: root.path)
        let coldFiles = await coldStore.files(inRoot: coldRoot.id)
        let source = try XCTUnwrap(coldFiles.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let result = try await WorkspaceSelectionMutationService(store: coldStore)
            .resolveAutomaticCodemapSelection(
                sourceFileIDs: [source.id],
                rootScope: .visibleWorkspace
            )

        XCTAssertEqual(
            result.targets.map(\.logicalPath.standardizedRelativePath),
            ["Sources/Target.swift"]
        )
        XCTAssertEqual(fixture.buildCount.value, warmBuildCount + 1)
        XCTAssertEqual(fixture.buildPriorities.values.last, .background)
        XCTAssertFalse(result.targets.contains {
            $0.logicalPath.standardizedRelativePath == "Sources/Unrelated.swift"
        })
        await coldStore.unloadRoot(id: coldRoot.id)
    }

    func testColdAutomaticSelectionUsesManifestEnvelopeAndCASWithoutUnrelatedBuild() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": "struct Target {}\n",
                "Sources/Unrelated.swift": "struct Unrelated {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }

        let warmStore = fixture.makeStore()
        let warmRoot = try await warmStore.loadRoot(path: root.path)
        let warmFiles = await warmStore.files(inRoot: warmRoot.id)
        for file in warmFiles {
            let ticket = try await pendingTicket(
                warmStore.requestCodemapArtifact(forFileID: file.id)
            )
            _ = try await readyResult(settledResult(store: warmStore, ticket: ticket))
        }
        let warmBuildCount = fixture.buildCount.value
        await warmStore.unloadRoot(id: warmRoot.id)

        let coldStore = fixture.makeStore()
        let coldRoot = try await coldStore.loadRoot(path: root.path)
        let coldFiles = await coldStore.files(inRoot: coldRoot.id)
        let source = try XCTUnwrap(coldFiles.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let service = WorkspaceSelectionMutationService(store: coldStore)
        let result = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(
            result.targets.map(\.logicalPath.standardizedRelativePath),
            ["Sources/Target.swift"]
        )
        XCTAssertEqual(fixture.buildCount.value, warmBuildCount)
        XCTAssertFalse(result.targets.contains {
            $0.logicalPath.standardizedRelativePath == "Sources/Unrelated.swift"
        })
        let receipt = try XCTUnwrap(result.publicationReceipt)
        let publication = await coldStore.revalidateAutomaticCodemapSelectionForPublication(
            receipt,
            rootScope: .visibleWorkspace
        )
        guard case let .current(targets) = publication else {
            return XCTFail("Expected current publication receipt")
        }
        XCTAssertEqual(targets, result.targets)

        await coldStore.unloadRoot(id: coldRoot.id)
        let stalePublication = await coldStore.revalidateAutomaticCodemapSelectionForPublication(
            receipt,
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(stalePublication, .stale(.publicationReceipt))
    }

    private func pendingTicket(
        _ result: WorkspaceCodemapArtifactDemandResult
    ) throws -> WorkspaceCodemapArtifactDemandTicket {
        guard case let .pending(ticket) = result else {
            throw CodemapStoreTestError.expectedPending
        }
        return ticket
    }

    private func readyResult(
        _ result: WorkspaceCodemapArtifactDemandResult
    ) throws -> WorkspaceCodemapArtifactDemandReady {
        guard case let .ready(ready) = result else {
            throw CodemapStoreTestError.expectedReady
        }
        return ready
    }

    private func frozenPresentationBundle(
        _ disposition: WorkspaceCodemapPresentationFreezeDisposition
    ) throws -> WorkspaceCodemapFrozenPresentationBundle {
        guard case let .ready(bundle) = disposition else {
            throw CodemapStoreTestError.expectedFrozenPresentationBundle
        }
        return bundle
    }

    private func renderedPresentationEntries(
        _ disposition: WorkspaceCodemapPresentationRenderDisposition,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [WorkspaceCodemapRenderedPresentationEntry] {
        guard case let .ready(entries) = disposition else {
            if case let .unavailable(reason) = disposition {
                XCTFail(
                    "Expected rendered presentation entries, got \(reason).",
                    file: file,
                    line: line
                )
            }
            throw CodemapStoreTestError.expectedRenderedPresentationEntries
        }
        return entries
    }

    private func assertPresentationFreezeUnavailable(
        _ disposition: WorkspaceCodemapPresentationFreezeDisposition,
        equals expected: WorkspaceCodemapPresentationFreezeUnavailableReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .unavailable(actual) = disposition else {
            return XCTFail(
                "Expected presentation freeze unavailability.",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func assertPresentationRenderUnavailable(
        _ disposition: WorkspaceCodemapPresentationRenderDisposition,
        equals expected: WorkspaceCodemapPresentationRenderUnavailableReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .unavailable(actual) = disposition else {
            return XCTFail(
                "Expected presentation render unavailability.",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func readyGraphQuery(
        store: WorkspaceFileContextStore,
        query: WorkspaceCodemapStoreSelectionGraphQuery,
        timeout: Duration = .seconds(15)
    ) async throws -> WorkspaceCodemapStoreSelectionGraphQueryResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var latest: WorkspaceCodemapStoreSelectionGraphQueryDisposition?
        while clock.now < deadline {
            let disposition = await store.queryCodemapSelectionGraph(query)
            latest = disposition
            if case let .readyPartial(result) = disposition {
                return result
            }
            switch disposition {
            case .busy, .stale(.runtime), .unavailable(.runtime):
                try await Task.sleep(for: .milliseconds(10))
            case .readyPartial, .unavailable, .stale, .budget:
                throw CodemapStoreTestError.expectedReadyGraph(disposition)
            }
        }
        if let latest {
            throw CodemapStoreTestError.expectedReadyGraph(latest)
        }
        throw CodemapStoreTestError.timedOut
    }

    private func settledResult(
        store: WorkspaceFileContextStore,
        ticket: WorkspaceCodemapArtifactDemandTicket,
        timeout: Duration = .seconds(15)
    ) async throws -> WorkspaceCodemapArtifactDemandResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let result = await store.codemapArtifactDemandStatus(ticket)
            if case .pending = result {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            return result
        }
        throw CodemapStoreTestError.timedOut
    }

    private func routeBecomesUnavailable(
        registry: WorkspaceCodemapBindingIntegrationRegistry,
        ticket: WorkspaceCodemapArtifactDemandTicket,
        relativePath: String
    ) async -> Bool {
        for _ in 0 ..< 500 {
            let candidate = await registry.makeBindingCatalogClient()
                .resolveManifestBinding(ticket.rootEpoch, relativePath)
            if candidate == nil { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func assertEngineRootCount(
        _ expected: Int,
        fixture: CodemapStoreFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let engine = try fixture.runtime().bindingEngine()
        let accounting = await engine.accounting()
        XCTAssertEqual(accounting.rootCount, expected, file: file, line: line)
    }

    private func engineRootCountBecomesZero(
        fixture: CodemapStoreFixture
    ) async throws -> Bool {
        let engine = try fixture.runtime().bindingEngine()
        for _ in 0 ..< 500 {
            if await engine.accounting().rootCount == 0 { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await engine.accounting().rootCount == 0
    }

    private func assertNonGitTerminal(
        _ result: WorkspaceCodemapArtifactDemandResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(.gitTerminal(.nonGit)) = result else {
            return XCTFail("Expected terminal non-Git unavailability.", file: file, line: line)
        }
    }

    private func assertCancelled(
        _ result: WorkspaceCodemapArtifactDemandResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(.cancelled) = result else {
            return XCTFail("Expected cancelled unavailability.", file: file, line: line)
        }
    }

    private func assertStale(
        _ result: WorkspaceCodemapArtifactDemandResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(.staleCurrentness) = result else {
            return XCTFail("Expected stale currentness.", file: file, line: line)
        }
    }

    private static func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

private enum CodemapStoreTestError: Error {
    case expectedFrozenPresentationBundle
    case expectedPending
    case expectedReady
    case expectedRenderedPresentationEntries
    case expectedReadyGraph(WorkspaceCodemapStoreSelectionGraphQueryDisposition)
    case timedOut
}

private final class CodemapStoreFixture: @unchecked Sendable {
    let registry = WorkspaceCodemapBindingIntegrationRegistry()
    let providerAccessCount = CodemapLockedCounter()
    let runtimeFactoryCount = CodemapLockedCounter()
    let engineFactoryCount = CodemapLockedCounter()
    let manifestReadCount = CodemapLockedCounter()
    let buildCount = CodemapLockedCounter()
    let buildPriorities = CodemapLockedValues<CodeMapArtifactBuildPriority>()

    private let sandbox: URL
    private let artifactRoot: URL
    private let freshRuntimeFactory: @Sendable () throws -> CodeMapArtifactRuntime
    private let runtimeProvider: CodeMapArtifactRuntimeProvider

    init(
        name: String,
        resolutionGate: CodemapResolutionGate? = nil,
        syntheticGraphArtifacts: Bool = false
    ) throws {
        let sandbox = try Self.makeSandbox(name: name)
        let artifactRoot = try Self.makeSecureDirectory(in: sandbox, named: "artifacts")
        let registry = registry
        let runtimeFactoryCount = runtimeFactoryCount
        let engineFactoryCount = engineFactoryCount
        let manifestReadCount = manifestReadCount
        let buildCount = buildCount
        let buildPriorities = buildPriorities
        let defaultBuilder = CodeMapArtifactBuilderClient()
        let freshRuntimeFactory: @Sendable () throws -> CodeMapArtifactRuntime = {
            runtimeFactoryCount.increment()
            return try CodeMapArtifactRuntime(
                rootURL: artifactRoot,
                manifestStoreHooks: CodeMapRootManifestStoreHooks(
                    afterReadAdmission: {
                        manifestReadCount.increment()
                    }
                ),
                builder: CodeMapArtifactBuilderClient(execute: { input, ownerID, priority in
                    buildCount.increment()
                    buildPriorities.append(priority)
                    if syntheticGraphArtifacts,
                       case let .decoded(source) = input.source.decodeResult
                    {
                        return CodeMapArtifactBuilderExecution(
                            outcome: .ready(Self.syntheticGraphArtifact(source.text)),
                            permitWaitNanoseconds: 0,
                            buildNanoseconds: 0
                        )
                    }
                    return try await defaultBuilder.execute(input, ownerID, priority)
                }),
                bindingIntegrationRegistry: registry,
                bindingEngineFactory: { runtime in
                    engineFactoryCount.increment()
                    return WorkspaceCodemapBindingEngine(
                        runtime: runtime,
                        capabilityService: WorkspaceCodemapGitCapabilityService(
                            namespaceSalt: Data(
                                repeating: 0x6C,
                                count: GitBlobRepositoryNamespace.saltByteCount
                            ),
                            hooks: WorkspaceCodemapGitCapabilityServiceHooks(
                                beforeResolution: {
                                    await resolutionGate?.enterAndWait()
                                }
                            )
                        ),
                        sourceReader: registry.makeValidatedSourceReaderClient(),
                        catalogClient: registry.makeBindingCatalogClient()
                    )
                }
            )
        }
        runtimeProvider = CodeMapArtifactRuntimeProvider(factory: freshRuntimeFactory)
        self.sandbox = sandbox
        self.artifactRoot = artifactRoot
        self.freshRuntimeFactory = freshRuntimeFactory
    }

    deinit {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func makeStore(
        codemapLocalGitClassificationProbe: WorkspaceCodemapLocalGitClassificationProbe = .init { _ in
            .requiresGitPreflight
        },
        codemapGitEligibilityProbe: WorkspaceCodemapGitEligibilityProbe = WorkspaceCodemapGitEligibilityProbe { _ in
            .eligible
        },
        selectionGraphFactory: WorkspaceCodemapSelectionGraphFactory = .production,
        selectionGraphQueryBudgetPolicy: WorkspaceCodemapStoreSelectionGraphQueryBudgetPolicy = .initial,
        automaticSelectionAccountingMaximum: Int = .max,
        cancellationCleanupHook: @escaping @Sendable (
            WorkspaceCodemapArtifactDemandTicket
        ) async -> Void = { _ in },
        readyPublicationHook: @escaping @Sendable (
            WorkspaceCodemapArtifactDemandTicket
        ) async -> Void = { _ in },
        demandResultHook: @escaping @Sendable (
            WorkspaceCodemapArtifactDemandTicket,
            WorkspaceCodemapBindingDemandResult
        ) async -> WorkspaceCodemapBindingDemandResult = { _, result in result },
        automaticSelectionQueryHook: @escaping @Sendable (
            WorkspaceCodemapRootEpoch
        ) async -> Void = { _ in }
    ) -> WorkspaceFileContextStore {
        let providerAccessCount = providerAccessCount
        let runtimeProvider = runtimeProvider
        return WorkspaceFileContextStore(
            codemapRuntimeProvider: {
                providerAccessCount.increment()
                return try runtimeProvider.runtime()
            },
            codemapLocalGitClassificationProbe: codemapLocalGitClassificationProbe,
            codemapGitEligibilityProbe: codemapGitEligibilityProbe,
            selectionGraphFactory: selectionGraphFactory,
            selectionGraphQueryBudgetPolicy: selectionGraphQueryBudgetPolicy,
            automaticSelectionAccountingMaximum: automaticSelectionAccountingMaximum,
            codemapCancellationCleanupHook: cancellationCleanupHook,
            codemapReadyPublicationHook: readyPublicationHook,
            codemapDemandResultHook: demandResultHook,
            codemapAutomaticSelectionQueryHook: automaticSelectionQueryHook
        )
    }

    func makeFreshStore() throws -> WorkspaceFileContextStore {
        let runtime = try freshRuntimeFactory()
        let providerAccessCount = providerAccessCount
        return WorkspaceFileContextStore(
            codemapRuntimeProvider: {
                providerAccessCount.increment()
                return runtime
            }
        )
    }

    func artifactURL(for key: CodeMapArtifactKey) -> URL {
        artifactRoot
            .appendingPathComponent("CodeMapArtifacts", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent(key.shard, isDirectory: true)
            .appendingPathComponent(key.storageDigestHex)
    }

    func makePlainRoot(files: [String: String]) throws -> URL {
        let root = sandbox.appendingPathComponent(
            "plain-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (relativePath, contents) in files {
            try Self.write(
                contents,
                to: root.appendingPathComponent(relativePath)
            )
        }
        return root
    }

    func runtime() throws -> CodeMapArtifactRuntime {
        try runtimeProvider.runtime()
    }

    func shutdown() async {
        if let runtime = try? runtimeProvider.runtime(),
           let engine = try? runtime.bindingEngine()
        {
            await engine.shutdown()
        }
    }

    static func makeSandbox(name: String) throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WorkspaceFileContextStoreCodemapSeamTests-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        return sandbox
    }

    private static func makeSecureDirectory(in parent: URL, named name: String) throws -> URL {
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(directory.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let resolvedPath = try directory.path.withCString { pointer -> String in
            guard let resolved = realpath(pointer, nil) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: resolvedPath, isDirectory: true)
    }

    private static func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func syntheticGraphArtifact(_ source: String) -> CodeMapSyntaxArtifact {
        let definitions: [String]
        let references: [String]
        if source.contains("let target: Target") {
            definitions = ["Source"]
            references = ["Target"]
        } else if source.contains("protocol FirstSource") {
            definitions = ["FirstSource"]
            references = ["FirstTarget"]
        } else if source.contains("protocol SecondSource") {
            definitions = ["SecondSource"]
            references = ["SecondTarget"]
        } else if source.contains("protocol SourceProtocol") {
            definitions = ["SourceProtocol"]
            if source.contains("ForeignDefinition") {
                references = ["ForeignDefinition"]
            } else if source.contains("FirstTarget"), source.contains("SecondTarget") {
                references = ["FirstTarget", "SecondTarget"]
            } else {
                references = ["Target"]
            }
        } else if source.contains("ForeignDefinition") {
            definitions = ["ForeignDefinition"]
            references = []
        } else if source.contains("FirstTarget") {
            definitions = ["FirstTarget"]
            references = []
        } else if source.contains("SecondTarget") {
            definitions = ["SecondTarget"]
            references = []
        } else if source.contains("Target") {
            definitions = ["Target"]
            references = []
        } else {
            definitions = []
            references = []
        }
        return CodeMapSyntaxArtifact(
            imports: [],
            classes: definitions.map { ClassInfo(name: $0, methods: [], properties: []) },
            functions: [],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: references
        )
    }
}

private final class CodemapSelectionGraphProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let admission: CodeMapSelectionGraphAdmission
    private let buildGate: CodemapSelectionGraphBuildGate?
    private let runtimePolicy: WorkspaceCodemapSelectionGraphRuntimePolicy
    private var graphsByRootEpoch: [WorkspaceCodemapRootEpoch: WorkspaceCodemapSelectionGraph] = [:]
    private var factoryInvocationCount = 0

    init(
        buildGate: CodemapSelectionGraphBuildGate? = nil,
        admissionPolicy: CodeMapSelectionGraphAdmissionPolicy = .init(
            maximumActiveReservationCount: 8,
            maximumReservedBindingCount: 100_000
        ),
        runtimePolicy: WorkspaceCodemapSelectionGraphRuntimePolicy = .initial
    ) {
        self.buildGate = buildGate
        admission = CodeMapSelectionGraphAdmission(policy: admissionPolicy)
        self.runtimePolicy = runtimePolicy
    }

    var factory: WorkspaceCodemapSelectionGraphFactory {
        WorkspaceCodemapSelectionGraphFactory { [self] rootEpoch in
            lock.withLock {
                factoryInvocationCount += 1
                let graph = WorkspaceCodemapSelectionGraph(
                    rootEpoch: rootEpoch,
                    policy: runtimePolicy,
                    admission: admission,
                    diagnostics: buildGate?.diagnostics ?? .none
                )
                graphsByRootEpoch[rootEpoch] = graph
                return graph
            }
        }
    }

    var factoryCount: Int {
        lock.withLock { factoryInvocationCount }
    }

    func graph(rootEpoch: WorkspaceCodemapRootEpoch) -> WorkspaceCodemapSelectionGraph? {
        lock.withLock { graphsByRootEpoch[rootEpoch] }
    }

    func waitUntilPublished(
        rootEpoch: WorkspaceCodemapRootEpoch,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let graph = graph(rootEpoch: rootEpoch),
               await (graph.accounting()).publishedSummary != nil
            {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func materializedQueryResultCount() async -> UInt64 {
        let graphs = lock.withLock { Array(graphsByRootEpoch.values) }
        var count: UInt64 = 0
        for graph in graphs {
            await count += (graph.accounting()).materializedQueryResultCount
        }
        return count
    }
}

private final class CodemapSelectionGraphBuildGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var blockedGenerations: [UInt64] = []
    private var releasedGenerations = Set<UInt64>()
    private var isOpen = false

    var diagnostics: WorkspaceCodemapSelectionGraphRuntimeDiagnostics {
        WorkspaceCodemapSelectionGraphRuntimeDiagnostics { [self] event in
            guard event.kind == .beforePublication else { return }
            block(generation: event.key.contributionGeneration.rawValue)
        }
    }

    func waitUntilFirstBlocked() -> UInt64? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 10)
        while blockedGenerations.isEmpty {
            guard condition.wait(until: deadline) else { return nil }
        }
        return blockedGenerations[0]
    }

    func waitUntilBlocked(after generation: UInt64) -> UInt64? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 10)
        while !blockedGenerations.contains(where: { $0 > generation }) {
            guard condition.wait(until: deadline) else { return nil }
        }
        return blockedGenerations.first(where: { $0 > generation })
    }

    func release(generation: UInt64) {
        condition.lock()
        releasedGenerations.insert(generation)
        condition.broadcast()
        condition.unlock()
    }

    func releaseAll() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }

    private func block(generation: UInt64) {
        condition.lock()
        guard !isOpen else {
            condition.unlock()
            return
        }
        blockedGenerations.append(generation)
        condition.broadcast()
        let deadline = Date(timeIntervalSinceNow: 10)
        while !isOpen, !releasedGenerations.contains(generation) {
            guard condition.wait(until: deadline) else { break }
        }
        condition.unlock()
    }
}

private final class CodemapLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class CodemapLockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.withLock { storage }
    }

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }
}

private actor CodemapSuspensionGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered(timeout: Duration = .seconds(10)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !entered, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return entered
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor CodemapArmableSuspensionGate {
    private var armed = false
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func arm() {
        armed = true
    }

    func enterIfArmedAndWait() async {
        guard armed else { return }
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered(timeout: Duration = .seconds(10)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !entered, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return entered
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor CodemapRootSuspensionGate {
    private var enteredRootEpoch: WorkspaceCodemapRootEpoch?
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func enterAndWait(_ rootEpoch: WorkspaceCodemapRootEpoch) async {
        guard enteredRootEpoch == nil else { return }
        enteredRootEpoch = rootEpoch
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered(timeout: Duration = .seconds(10)) async -> WorkspaceCodemapRootEpoch? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while enteredRootEpoch == nil, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return enteredRootEpoch
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor CodemapResolutionGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var resolutionCount = 0

    func enterAndWait() async {
        resolutionCount += 1
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered(timeout: Duration = .seconds(10)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !entered, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return entered
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
