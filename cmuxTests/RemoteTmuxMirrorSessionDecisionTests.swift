import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct RemoteTmuxMirrorSessionDecisionTests {
    private func session(_ name: String, id: Int) -> RemoteTmuxSession {
        RemoteTmuxSession(id: "$\(id)", name: name, windowCount: 1, attached: false, createdUnix: nil)
    }

    @Test func absentPtmuxAndEmptyListAllowsBlankSession() {
        let decision = RemoteTmuxMirrorSessionDecision(
            liveSessions: [], persistentNames: nil, onlySession: nil, createIfEmpty: true
        )
        #expect(decision.shouldCreateBlankSession)
        #expect(decision.sessions.isEmpty)
    }

    @Test func persistentNamesSuppressBlankSession() {
        let decision = RemoteTmuxMirrorSessionDecision(
            liveSessions: [], persistentNames: ["work"], onlySession: nil, createIfEmpty: true
        )
        #expect(!decision.shouldCreateBlankSession)
    }

    @Test func emptyPersistentRegistryAllowsBlankSession() {
        let decision = RemoteTmuxMirrorSessionDecision(
            liveSessions: [], persistentNames: [], onlySession: nil, createIfEmpty: true
        )
        #expect(decision.shouldCreateBlankSession)
    }

    @Test func persistentNamesLeadWithoutReorderingOtherSessions() {
        let live = [session("extra-b", id: 0), session("work", id: 1),
                    session("extra-a", id: 2), session("main", id: 3)]
        let decision = RemoteTmuxMirrorSessionDecision(
            liveSessions: live, persistentNames: ["main", "work"], onlySession: nil, createIfEmpty: true
        )
        #expect(decision.sessions.map(\.name) == ["main", "work", "extra-b", "extra-a"])
    }

    @Test func onlySessionFiltersAfterOrdering() {
        let decision = RemoteTmuxMirrorSessionDecision(
            liveSessions: [session("other", id: 0), session("work", id: 1)],
            persistentNames: ["work"], onlySession: "work", createIfEmpty: true
        )
        #expect(decision.sessions.map(\.name) == ["work"])
        #expect(!decision.requestedSessionMissing)
    }

    @Test func missingOnlySessionNeverMirrorsEverythingOrCreatesBlank() {
        let decision = RemoteTmuxMirrorSessionDecision(
            liveSessions: [session("other", id: 0)], persistentNames: [],
            onlySession: "missing", createIfEmpty: true
        )
        #expect(decision.sessions.isEmpty)
        #expect(decision.requestedSessionMissing)
        #expect(!decision.shouldCreateBlankSession)
    }
}
