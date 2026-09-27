import Foundation

struct TerminalRecoveryAgentIdentity: Codable, Hashable, Sendable {
    let kind: String
    let sessionID: String

    init?(kind: String?, sessionID: String?) {
        guard let kind = kind?.trimmingCharacters(in: .whitespacesAndNewlines), !kind.isEmpty,
              let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty else {
            return nil
        }
        self.kind = kind
        self.sessionID = sessionID
    }
}

struct TerminalRecoveryObservation: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case agent, shell, otherProcess, unknown }

    var surfaceID: UUID?
    var generation: UInt64
    var observedAt: Date
    var persistedAt: Date
    var state: State
    var agent: TerminalRecoveryAgentIdentity?
    var provenance: String
    var cwd: String?
    var lastKnownAgent: TerminalRecoveryAgentIdentity?
    var diagnosticReason: String?

    static func migrated(from snapshot: SessionTerminalPanelSnapshot, surfaceID: UUID? = nil, now: Date = Date()) -> Self {
        let binding = snapshot.managedAgentResumeBinding ?? snapshot.resumeBinding
        let boundIdentity = TerminalRecoveryAgentIdentity(kind: binding?.kind, sessionID: binding?.checkpointId)
        let savedIdentity = TerminalRecoveryAgentIdentity(kind: snapshot.agent?.kind.rawValue, sessionID: snapshot.agent?.sessionId)
        let bindingIsManaged = binding?.isAgentHookBinding == true || binding?.hasCompleteManagedSessionIdentity == true
        let conflictingIdentity = boundIdentity != nil && savedIdentity != nil && boundIdentity != savedIdentity
        let identity = bindingIsManaged ? (boundIdentity ?? savedIdentity) : savedIdentity
        let confirmed = snapshot.wasAgentRunning == true && identity != nil &&
            (binding == nil || bindingIsManaged) && !conflictingIdentity
        let state: State = snapshot.wasAgentRunning == false ? .shell : (confirmed ? .agent : .unknown)
        return Self(
            surfaceID: surfaceID, generation: 0, observedAt: now, persistedAt: now,
            state: state, agent: confirmed ? identity : nil,
            provenance: binding?.source ?? (savedIdentity == nil ? "legacy-snapshot" : "snapshot-agent"), cwd: snapshot.workingDirectory,
            lastKnownAgent: identity ?? savedIdentity,
            diagnosticReason: state == .unknown ? "agent identity or running state was not confirmed" : nil
        )
    }

    /// A failed scan preserves the last confirmed observation; an older scan cannot replace a newer one.
    func accepting(
        _ candidate: Self?, expectedGeneration: UInt64, now: Date,
        refreshObservedAt: Bool = false
    ) -> Self {
        guard var candidate, generation == expectedGeneration else { return self }
        let changed = state != candidate.state || agent != candidate.agent ||
            provenance != candidate.provenance || cwd != candidate.cwd ||
            lastKnownAgent != candidate.lastKnownAgent || diagnosticReason != candidate.diagnosticReason
        candidate.generation = changed ? generation &+ 1 : generation
        candidate.observedAt = changed || refreshObservedAt ? now : observedAt
        candidate.persistedAt = now
        return candidate
    }
}

struct TerminalRecoveryPlan: Equatable, Sendable {
    enum Action: Equatable, Sendable { case attachSession, resumeAgent(TerminalRecoveryAgentIdentity), shell }
    let action: Action
    let reason: String

    static func decide(
        observation: TerminalRecoveryObservation,
        hasRemotePTY: Bool = false,
        hasLocalTmux: Bool = false,
        hasHibernation: Bool = false,
        surfaceID: UUID? = nil,
        claimedOwnerSurfaceID: UUID? = nil
    ) -> Self {
        if hasRemotePTY || hasLocalTmux || hasHibernation {
            return Self(action: .attachSession, reason: "persistent session attachment")
        }
        if observation.state == .agent, let agent = observation.agent {
            if let surfaceID, let recordedOwner = observation.surfaceID, recordedOwner != surfaceID {
                return Self(action: .shell, reason: "agent binding belongs to another surface")
            }
            if let surfaceID, let claimedOwnerSurfaceID, claimedOwnerSurfaceID != surfaceID {
                return Self(action: .shell, reason: "agent session already owned by another surface")
            }
            return Self(action: .resumeAgent(agent), reason: "confirmed surface agent")
        }
        return Self(action: .shell, reason: observation.diagnosticReason ?? observation.state.rawValue)
    }
}

extension SessionTerminalPanelSnapshot {
    func recordingRecovery(
        surfaceID: UUID,
        previous: TerminalRecoveryObservation?,
        unavailableReason: String? = nil,
        freshEvidence: Bool = false,
        foregroundOtherProcess: Bool = false,
        confirmedShell: Bool = false,
        now: Date = Date()
    ) -> Self {
        var snapshot = self
        var candidate = TerminalRecoveryObservation.migrated(from: self, surfaceID: surfaceID, now: now)
        if candidate.state == .unknown && candidate.lastKnownAgent == nil {
            if foregroundOtherProcess {
                candidate.state = .otherProcess
                candidate.provenance = "shell-integration"
                candidate.diagnosticReason = nil
            } else if confirmedShell {
                candidate.state = .shell
                candidate.provenance = "shell-integration"
                candidate.diagnosticReason = nil
            }
        }
        if let unavailableReason {
            var retained = previous ?? candidate
            if previous == nil {
                retained.state = .unknown
                retained.agent = nil
            }
            retained.diagnosticReason = unavailableReason
            retained.persistedAt = now
            snapshot.recovery = retained
            return snapshot
        }
        if let previous {
            candidate.lastKnownAgent = candidate.lastKnownAgent ?? previous.lastKnownAgent
            if !freshEvidence && wasAgentRunning == nil && candidate.state == .unknown && previous.state == .agent {
                var retained = previous
                retained.diagnosticReason = previous.diagnosticReason
                    ?? "current process evidence unavailable; last agent observation retained"
                retained.persistedAt = now
                snapshot.recovery = retained
            } else {
                snapshot.recovery = previous.accepting(
                    candidate, expectedGeneration: previous.generation, now: now,
                    refreshObservedAt: freshEvidence
                )
            }
        } else {
            snapshot.recovery = candidate
        }
        return freshEvidence ? snapshot.reconcilingConfirmedAgentBinding(surfaceID: surfaceID) : snapshot
    }

    /// Retirement clears the hook's automatic-launch bit without changing its
    /// approval policy. A newer confirmed observation of the same running agent
    /// must not carry that retired bit into the next deferred launch.
    func reconcilingConfirmedAgentBinding(surfaceID: UUID) -> Self {
        guard wasAgentRunning == true, let recovery,
              recovery.surfaceID == surfaceID, recovery.state == .agent,
              let observedAgent = recovery.agent else { return self }
        var candidate = self
        for keyPath in [\Self.resumeBinding, \Self.managedAgentResumeBinding] {
            guard var binding = candidate[keyPath: keyPath],
                  binding.isAgentHookBinding, binding.autoResume == false,
                  binding.approvalPolicy == .auto,
                  TerminalRecoveryAgentIdentity(kind: binding.kind, sessionID: binding.checkpointId) == observedAgent
            else { continue }
            binding.autoResume = true
            candidate[keyPath: keyPath] = binding
        }
        // Keep attachment precedence, identity conflict checks, and ownership
        // checks in the same recovery policy used by both terminal containers.
        guard candidate.recoveryPlan(surfaceID: surfaceID).action == .resumeAgent(observedAgent) else {
            return self
        }
        return candidate
    }

    func recoveryPlan(surfaceID: UUID? = nil, claimedOwnerSurfaceID: UUID? = nil) -> TerminalRecoveryPlan {
        let observation = recovery ?? .migrated(from: self, surfaceID: surfaceID)
        let savedAgent = TerminalRecoveryAgentIdentity(kind: agent?.kind.rawValue, sessionID: agent?.sessionId)
        let savedBinding = TerminalRecoveryAgentIdentity(
            kind: (managedAgentResumeBinding ?? resumeBinding)?.kind,
            sessionID: (managedAgentResumeBinding ?? resumeBinding)?.checkpointId
        )
        let savedIdentities = [savedAgent, savedBinding].compactMap { $0 }
        let hasLocalTmux = tmuxStartCommand?.contains("CMUX_LOCAL_TMUX=1") == true
        let hasAttachment = remotePTYSessionID?.isEmpty == false ||
            hasLocalTmux || hibernation != nil
        let binding = managedAgentResumeBinding ?? resumeBinding
        if !hasAttachment, binding?.isAgentHookBinding == true,
           binding?.autoResume != true, binding?.approvalPolicy == .manual {
            return TerminalRecoveryPlan(action: .shell, reason: "agent binding requires manual resume")
        }
        if !hasAttachment, observation.state == .agent,
           let observedAgent = observation.agent,
           (savedIdentities.isEmpty || savedIdentities.contains(where: { $0 != observedAgent })) {
            return TerminalRecoveryPlan(action: .shell, reason: "saved agent identity conflicts with recovery observation")
        }
        return TerminalRecoveryPlan.decide(
            observation: observation,
            hasRemotePTY: remotePTYSessionID?.isEmpty == false,
            hasLocalTmux: hasLocalTmux,
            hasHibernation: hibernation != nil,
            surfaceID: surfaceID,
            claimedOwnerSurfaceID: claimedOwnerSurfaceID
        )
    }
}
