import Foundation

/// Pure discovery decision shared by ordinary tmux and ptmux-backed hosts.
struct RemoteTmuxMirrorSessionDecision {
    let sessions: [RemoteTmuxSession]
    let shouldCreateBlankSession: Bool
    let requestedSessionMissing: Bool

    init(
        liveSessions: [RemoteTmuxSession],
        persistentNames: [String]?,
        onlySession: String?,
        createIfEmpty: Bool
    ) {
        let ordered: [RemoteTmuxSession]
        if let persistentNames {
            let rank = Dictionary(persistentNames.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
            ordered = liveSessions.enumerated().sorted { left, right in
                let leftRank = rank[left.element.name] ?? Int.max
                let rightRank = rank[right.element.name] ?? Int.max
                return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
            }.map(\.element)
        } else {
            ordered = liveSessions
        }
        sessions = onlySession.map { name in ordered.filter { $0.name == name } } ?? ordered
        requestedSessionMissing = onlySession != nil && sessions.isEmpty
        shouldCreateBlankSession = createIfEmpty && onlySession == nil && liveSessions.isEmpty
            && (persistentNames?.isEmpty ?? true)
    }
}
