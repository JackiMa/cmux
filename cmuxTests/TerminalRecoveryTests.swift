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
}
