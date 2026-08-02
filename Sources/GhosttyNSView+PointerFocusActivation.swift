import CmuxTerminalCore

extension GhosttyNSView {
    func activateContainerFocusFromPointerDown() {
        guard let terminalSurface else { return }

        switch terminalSurface.focusPlacement {
        case .workspace:
            AppDelegate.shared?.noteTerminalKeyboardFocusIntent(
                workspaceId: terminalSurface.tabId,
                panelId: terminalSurface.id,
                in: window
            )
        case .rightSidebarDock:
            DockSplitStore.focusPanelFromDockPointer(terminalSurface.id, window: window)
        }
    }

    func terminalPointerShouldForwardActivation() -> Bool {
        guard let terminalSurface else { return false }
        guard desiredFocus else { return false }

        switch terminalSurface.focusPlacement {
        case .workspace:
            guard let workspace = terminalSurface.owningWorkspace() else { return false }
            if workspace.isFocusedTerminalInputSurface(terminalSurface.id) { return true }
            // A mirrored tmux pane's active-pane projection is confirmed by the
            // remote asynchronously. The pointer-down that lands in this pane
            // has already asked tmux to select it, so the pane owns pointer
            // input for its own surface even while that round trip is
            // outstanding.
            return workspace.remoteTmuxControlPane(surfaceID: terminalSurface.id) != nil
        case .rightSidebarDock:
            return TerminalPointerFocusActivationPolicy().shouldForwardToTerminal(
                currentPanelId: terminalSurface.id,
                focusedPanelId: DockSplitStore.liveStore(containingPanel: terminalSurface.id)?.focusedPanelId
            )
        }
    }
}
