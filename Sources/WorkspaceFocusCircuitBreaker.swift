import Bonsplit
import Foundation

/// Bounds repeated focus work for an unchanged Bonsplit selection.
struct WorkspaceFocusCircuitBreaker {
    struct Key: Equatable {
        let pane: PaneID?
        let tab: TabID?
        let panel: UUID
    }

    private var reassertKey: Key?
    private var reassertStart: TimeInterval = 0
    private var reassertCount = 0
    private var reconcileKey: Key?
    private var reconcileStart: TimeInterval = 0
    private var reconcileCount = 0

    mutating func resetReassert() {
        reassertKey = nil
        reassertCount = 0
    }

    mutating func resetReconcile() {
        reconcileKey = nil
        reconcileCount = 0
    }

    mutating func breakReassert(key: Key, converged: Bool, now: TimeInterval) -> Bool {
        guard converged else { resetReassert(); return false }
        return Self.hit(key: key, now: now, storedKey: &reassertKey, started: &reassertStart, count: &reassertCount)
    }

    mutating func breakReconcile(key: Key, now: TimeInterval) -> Bool {
        Self.hit(key: key, now: now, storedKey: &reconcileKey, started: &reconcileStart, count: &reconcileCount)
    }

    private static func hit(
        key: Key,
        now: TimeInterval,
        storedKey: inout Key?,
        started: inout TimeInterval,
        count: inout Int
    ) -> Bool {
        if storedKey != key || now - started > 2 {
            storedKey = key
            started = now
            count = 0
        }
        guard count >= 20 else {
            count += 1
            return false
        }
        return true
    }
}
