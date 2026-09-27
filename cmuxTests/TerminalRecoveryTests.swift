import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct TerminalRecoveryTests {
    private func agent(_ id: String) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(kind: .codex, sessionId: id, workingDirectory: nil, launchCommand: nil)
    }

    @Test func legacyUnknownKeepsManualIdentityWithoutAutoResume() {
        let snapshot = SessionTerminalPanelSnapshot(agent: agent("manual-id"))
        let observation = TerminalRecoveryObservation.migrated(from: snapshot)
        #expect(observation.state == .unknown)
        #expect(observation.lastKnownAgent?.sessionID == "manual-id")
        #expect(snapshot.recoveryPlan().action == .shell)
    }

    @Test func missingSessionIDCannotConfirmAnAgent() {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex", command: "codex", source: "agent-hook"
        )
        let snapshot = SessionTerminalPanelSnapshot(resumeBinding: binding, wasAgentRunning: true)
        #expect(snapshot.recoveryPlan().action == .shell)
    }

    @Test func runningAgentUsesExactSurfaceSession() {
        let surfaceID = UUID()
        let snapshot = SessionTerminalPanelSnapshot(
            agent: agent("exact-id"), wasAgentRunning: true
        )
        let plan = snapshot.recoveryPlan(surfaceID: surfaceID)
        #expect(plan.action == .resumeAgent(TerminalRecoveryAgentIdentity(kind: "codex", sessionID: "exact-id")!))
    }

    @Test func exitedAgentBecomesShellAndRetainsManualIdentity() {
        let snapshot = SessionTerminalPanelSnapshot(agent: agent("old-id"), wasAgentRunning: false)
        let observation = TerminalRecoveryObservation.migrated(from: snapshot)
        #expect(observation.state == .shell)
        #expect(observation.lastKnownAgent?.sessionID == "old-id")
        #expect(snapshot.recoveryPlan().action == .shell)
    }

    @Test func foregroundOtherProcessRestoresAsShell() {
        let snapshot = SessionTerminalPanelSnapshot(workingDirectory: "/tmp")
            .recordingRecovery(
                surfaceID: UUID(), previous: nil, foregroundOtherProcess: true
            )
        #expect(snapshot.recovery?.state == .otherProcess)
        #expect(snapshot.recoveryPlan().action == .shell)
    }

    @Test func persistentSessionAttachmentWinsOverAgent() {
        let base = SessionTerminalPanelSnapshot(agent: agent("exact-id"), wasAgentRunning: true)
        #expect(SessionTerminalPanelSnapshot(
            agent: base.agent, remotePTYSessionID: "pty-id", wasAgentRunning: true
        ).recoveryPlan().action == .attachSession)
        #expect(SessionTerminalPanelSnapshot(
            agent: base.agent,
            tmuxStartCommand: "TMUX= CMUX_LOCAL_TMUX=1 exec /usr/bin/tmux -S /tmp/server.sock attach",
            wasAgentRunning: true
        ).recoveryPlan().action == .attachSession)
        #expect(SessionTerminalPanelSnapshot(
            agent: base.agent, tmuxStartCommand: "tmux attach", wasAgentRunning: true
        ).recoveryPlan().action == .resumeAgent(
            TerminalRecoveryAgentIdentity(kind: "codex", sessionID: "exact-id")!
        ))
    }

    @Test func duplicateSessionDoesNotResumeOnSecondSurface() {
        let first = UUID()
        let second = UUID()
        let snapshot = SessionTerminalPanelSnapshot(agent: agent("shared-id"), wasAgentRunning: true)
        let owned = snapshot.recordingRecovery(surfaceID: first, previous: nil)
        #expect(owned.recoveryPlan(surfaceID: first).action == .resumeAgent(
            TerminalRecoveryAgentIdentity(kind: "codex", sessionID: "shared-id")!
        ))
        #expect(owned.recoveryPlan(surfaceID: second).action == .shell)
        #expect(snapshot.recoveryPlan(surfaceID: second, claimedOwnerSurfaceID: first).action == .shell)
    }

    @Test func staleGenerationCannotOverwriteNewerObservation() {
        let snapshot = SessionTerminalPanelSnapshot(agent: agent("current"), wasAgentRunning: true)
        var current = TerminalRecoveryObservation.migrated(from: snapshot)
        current.generation = 2
        let old = TerminalRecoveryObservation.migrated(from: SessionTerminalPanelSnapshot(wasAgentRunning: false))
        #expect(current.accepting(old, expectedGeneration: 1, now: Date()).state == .agent)
        #expect(current.accepting(old, expectedGeneration: 2, now: Date()).state == .shell)
    }

    @Test func failedScanRetainsConfirmedAgentAndRecordsReason() {
        let surfaceID = UUID()
        let running = SessionTerminalPanelSnapshot(agent: agent("retained-id"), wasAgentRunning: true)
            .recordingRecovery(surfaceID: surfaceID, previous: nil)
        let previous = running.recovery!
        let unavailable = SessionTerminalPanelSnapshot(agent: agent("retained-id"))
            .recordingRecovery(
                surfaceID: surfaceID,
                previous: previous,
                unavailableReason: "scan timed out"
            )
        #expect(unavailable.recovery?.state == .agent)
        #expect(unavailable.recovery?.agent?.sessionID == "retained-id")
        #expect(unavailable.recovery?.generation == previous.generation)
        #expect(unavailable.recovery?.diagnosticReason == "scan timed out")
    }

    @MainActor
    @Test(arguments: [RestorableAgentKind.codex, .claude, .grok])
    func confirmedRunningAgentRepairsRetiredAutomaticBinding(kind: RestorableAgentKind) throws {
        let suite = "cmux-recovery-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { source.teardownAllPanels() }
        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let panelID = try #require(snapshot.panels.first?.id)
        let identity = "recovery-\(UUID().uuidString)"
        snapshot.panels[0].terminal = SessionTerminalPanelSnapshot(
            agent: SessionRestorableAgentSnapshot(
                kind: kind, sessionId: identity, workingDirectory: "/tmp", launchCommand: nil
            ),
            resumeBinding: SurfaceResumeBindingSnapshot(
                kind: kind.rawValue, command: "/usr/bin/true", cwd: "/tmp",
                checkpointId: identity, source: "agent-hook", autoResume: false,
                approvalPolicy: .auto
            ),
            wasAgentRunning: true
        ).recordingRecovery(surfaceID: panelID, previous: nil, freshEvidence: true)
        // Reproduce the contradictory snapshot written by the previous build.
        snapshot.panels[0].terminal?.resumeBinding?.autoResume = false

        let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { restored.teardownAllPanels() }
        let mapping = restored.restoreSessionSnapshot(snapshot, startupRestoreCommitOwner: .tabManagerTopology)
        let restoredID = try #require(mapping[panelID])
        let pending = try #require(restored.deferredAgentResumeRestoresByPanelId[restoredID])
        #expect(pending.resumeBinding?.autoResume == true)
        #expect(pending.resumeBinding?.checkpointId == identity)
        #expect(restored.surfaceResumeBindingsByPanelId[restoredID]?.autoResume == true)

        let dock = DockSplitStore(
            workspaceId: UUID(), baseDirectoryProvider: { "/tmp" },
            agentSessionAutoResumeDefaults: defaults, restorableAgentIndexProvider: { nil }
        )
        defer { dock.closeAllPanels() }
        let dockMapping = dock.restoreSessionSnapshot(SessionSplitContainerSnapshot(
            focusedPanelId: panelID, layout: snapshot.layout, panels: snapshot.panels
        ))
        let dockID = try #require(dockMapping[panelID])
        #expect(dock.deferredAgentResumeRestoresByPanelId[dockID]?.resumeBinding?.autoResume == true)
        #expect(dock.surfaceResumeBindingsByPanelId[dockID]?.checkpointId == identity)
    }

    @Test func explicitManualApprovalDoesNotAutoResume() {
        let surfaceID = UUID()
        let snapshot = SessionTerminalPanelSnapshot(
            agent: agent("manual-id"),
            resumeBinding: SurfaceResumeBindingSnapshot(
                kind: "codex", command: "/usr/bin/true", checkpointId: "manual-id",
                source: "agent-hook", autoResume: false, approvalPolicy: .manual
            ),
            wasAgentRunning: true
        ).recordingRecovery(surfaceID: surfaceID, previous: nil, freshEvidence: true)
        #expect(snapshot.recoveryPlan(surfaceID: surfaceID).action == .shell)
        #expect(snapshot.resumeBinding?.autoResume == false)
    }

    @Test func unknownExitedOrForeignSurfaceCannotReenableABinding() {
        let surfaceID = UUID()
        let running = SessionTerminalPanelSnapshot(
            agent: agent("exact-id"),
            resumeBinding: SurfaceResumeBindingSnapshot(
                kind: "codex", command: "/usr/bin/true", checkpointId: "exact-id",
                source: "agent-hook", autoResume: false, approvalPolicy: .auto
            ),
            wasAgentRunning: true
        ).recordingRecovery(surfaceID: surfaceID, previous: nil)
        #expect(running.reconcilingConfirmedAgentBinding(surfaceID: UUID()).resumeBinding?.autoResume == false)
        var exited = running
        exited.wasAgentRunning = false
        #expect(exited.reconcilingConfirmedAgentBinding(surfaceID: surfaceID).resumeBinding?.autoResume == false)
        var unknown = running
        unknown.recovery?.state = .unknown
        #expect(unknown.reconcilingConfirmedAgentBinding(surfaceID: surfaceID).resumeBinding?.autoResume == false)
        var conflicting = running
        conflicting.agent = agent("different-id")
        #expect(conflicting.reconcilingConfirmedAgentBinding(surfaceID: surfaceID).resumeBinding?.autoResume == false)
        var prompt = running
        prompt.resumeBinding?.approvalPolicy = .prompt
        #expect(prompt.reconcilingConfirmedAgentBinding(surfaceID: surfaceID).resumeBinding?.autoResume == false)
        var persistent = running
        persistent.remotePTYSessionID = "remote-pty"
        #expect(persistent.reconcilingConfirmedAgentBinding(surfaceID: surfaceID).resumeBinding?.autoResume == false)
    }
}
