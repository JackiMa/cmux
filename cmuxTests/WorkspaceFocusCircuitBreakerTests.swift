import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized) struct WorkspaceFocusCircuitBreakerTests {
    #if canImport(cmux_DEV) || canImport(cmux)
    @Test func convergedBonsplitFocusCallbackDoesNotReapplySelection() throws {
        let fixture = TerminalPortalTestWorkspace()
        defer { fixture.tearDown() }
        let workspace = fixture.workspace
        let pane = try #require(workspace.bonsplitController.focusedPaneId)
        let tab = try #require(workspace.bonsplitController.selectedTab(inPane: pane))
        let panelId = try #require(workspace.panelIdFromSurfaceId(tab.id))
        #expect(workspace.focusedPanelId == panelId)

        let before = workspace.debugApplyTabSelectionNowCount
        workspace.splitTabBar(workspace.bonsplitController, didFocusPane: pane)
        #expect(workspace.debugApplyTabSelectionNowCount == before)

        let reassertsBefore = workspace.debugReassertingApplyTabSelectionNowCount
        workspace.focusPanel(panelId, trigger: .terminalFirstResponder)
        #expect(workspace.debugReassertingApplyTabSelectionNowCount == reassertsBefore)
    }
    #endif
    @Test func identicalConvergedReassertStopsAfterTwentyHits() {
        var breaker = WorkspaceFocusCircuitBreaker()
        let key = WorkspaceFocusCircuitBreaker.Key(pane: PaneID(), tab: TabID(), panel: UUID())
        for _ in 0..<20 {
            let broken = breaker.breakReassert(key: key, converged: true, now: 1)
            #expect(!broken)
        }
        let broken = breaker.breakReassert(key: key, converged: true, now: 1)
        #expect(broken)
        let unconverged = breaker.breakReassert(key: key, converged: false, now: 1)
        #expect(!unconverged)
        let reset = breaker.breakReassert(key: key, converged: true, now: 1)
        #expect(!reset)
    }

    @Test func reassertResetsOnTargetChangeAndAfterWindow() {
        var breaker = WorkspaceFocusCircuitBreaker()
        let first = WorkspaceFocusCircuitBreaker.Key(pane: PaneID(), tab: TabID(), panel: UUID())
        let second = WorkspaceFocusCircuitBreaker.Key(pane: PaneID(), tab: TabID(), panel: UUID())
        for _ in 0..<21 { _ = breaker.breakReassert(key: first, converged: true, now: 1) }
        let changed = breaker.breakReassert(key: second, converged: true, now: 1)
        #expect(!changed)
        for _ in 0..<20 { _ = breaker.breakReassert(key: second, converged: true, now: 1) }
        let expired = breaker.breakReassert(key: second, converged: true, now: 4)
        #expect(!expired)
    }

    @Test func identicalReconcileTupleStopsAfterTwentyHits() {
        var breaker = WorkspaceFocusCircuitBreaker()
        let key = WorkspaceFocusCircuitBreaker.Key(pane: PaneID(), tab: TabID(), panel: UUID())
        for _ in 0..<20 {
            let broken = breaker.breakReconcile(key: key, now: 1)
            #expect(!broken)
        }
        let broken = breaker.breakReconcile(key: key, now: 1)
        #expect(broken)
        breaker.resetReconcile()
        let reset = breaker.breakReconcile(key: key, now: 1)
        #expect(!reset)
    }
}
