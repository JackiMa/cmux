import Bonsplit
import CmuxPanes
import Foundation

extension Workspace: TerminalLinkOpenContainer {
    var terminalLinkContainerDebugName: String {
        "workspace:\(id.uuidString)"
    }

    func terminalLinkWorkingDirectory(for sourcePanelId: UUID) -> String? {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return nil }
        return CommandClickFileOpenRouter.resolveWorkingDirectory(
            workspace: self,
            surfaceId: target.surfaceID
        )
    }

    func terminalLinkIsRemoteTerminal(_ sourcePanelId: UUID) -> Bool {
        let surfaceID = surfaceOwnershipTarget(for: sourcePanelId)?.surfaceID
            ?? sourcePanelId
        return !canResolveTerminalPathsAgainstLocalFilesystem(
            surfaceID: surfaceID
        )
    }

    func remoteTmuxPreviewContext(for sourcePanelId: UUID) -> RemoteTmuxPreviewContext? {
        guard let location = remoteTmuxControlPane(surfaceID: sourcePanelId),
              location.pane.panel.id == sourcePanelId,
              let host = location.windowMirror?.connection?.host ?? remoteTmuxSessionMirror?.host else {
            return nil
        }
        return RemoteTmuxPreviewContext(
            host: host,
            paneId: location.pane.tmuxPaneID
        )
    }

    func cloudTerminalLinkTarget(url: URL, sourcePanelId: UUID) -> CloudTerminalLinkTarget? {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId),
              let resource = SurfaceCatalog.shared.resource(forPanel: target.surfaceID)
                ?? SurfaceCatalog.shared.resource(forPanel: target.containerPanelID),
              let address = SurfaceCatalog.shared.machineInfo(for: resource.machine)?.privateAddress,
              let target = CmuxTuiSurfaceProvider.cloudTerminalLinkTarget(url: url, resource: resource, privateAddress: address) else { return nil }
        return target
    }

    func deferTerminalFileLinkOpen(
        sourcePanelId: UUID,
        filePath: String,
        fallback: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return false }
        CommandClickFileOpenRouter.deferredOpenFileInCmux(
            workspace: self,
            preferredWorkspaceId: id,
            surfaceId: target.containerPanelID,
            filePath: filePath,
            fallback: fallback
        )
        return true
    }

    func openTerminalBrowserLink(url: URL, sourcePanelId: UUID, focus: Bool = true) -> Bool {
        openTerminalBrowserPanel(url: url, sourcePanelId: sourcePanelId, focus: focus) != nil
    }

    func openTerminalBrowserPanel(url: URL, sourcePanelId: UUID, focus: Bool) -> BrowserPanel? {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return nil }
        if let targetPane = preferredRightSideTargetPane(fromPanelId: target.containerPanelID) {
            return newBrowserSurface(
                inPane: targetPane, url: url, focus: focus,
                allowsExternalBrowserFallback: !isRemoteTmuxMirror
            )
        }
        return newBrowserSplit(
            from: target.containerPanelID,
            orientation: .horizontal,
            url: url,
            focus: focus,
            allowsExternalBrowserFallback: !isRemoteTmuxMirror
        )
    }
}

extension Workspace {
    /// Finds the tmux window strip independently of focus in a local preview.
    func remoteTmuxWindowsPaneId() -> PaneID? {
        bonsplitController.allPaneIds.first { pane in
            bonsplitController.tabs(inPane: pane).contains { tab in
                panelIdFromSurfaceId(tab.id).map { panels[$0] is TerminalPanel } == true
            }
        } ?? bonsplitController.allPaneIds.first { bonsplitController.tabs(inPane: $0).isEmpty }
    }

    /// Reuses one outer pane for browsers and downloaded remote files.
    func remoteTmuxPreviewPaneId() -> PaneID? {
        guard isRemoteTmuxMirror else { return nil }
        return bonsplitController.allPaneIds.first { pane in
            let tabs = bonsplitController.tabs(inPane: pane)
            return !tabs.isEmpty && tabs.allSatisfy { tab in
                guard let panelId = panelIdFromSurfaceId(tab.id), let panel = panels[panelId] else { return false }
                return panel is BrowserPanel || panel is FilePreviewPanel
            }
        }
    }

    /// Grants a synchronous split only for the local preview being installed.
    func performRemoteTmuxPreviewSplit<T>(_ split: () -> T) -> T {
        let previous = isCreatingRemoteTmuxPreviewSplit
        isCreatingRemoteTmuxPreviewSplit = isRemoteTmuxMirror
        defer { isCreatingRemoteTmuxPreviewSplit = previous }
        return split()
    }
}
