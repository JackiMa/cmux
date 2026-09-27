import Bonsplit
import CmuxWorkspaces
import Foundation
import os

@MainActor
extension Workspace {
    var remoteTmuxSessionSnapshot: SessionRemoteTmuxWorkspaceSnapshot? {
        guard isRemoteTmuxMirror else { return nil }
        var snapshot = remoteTmuxRestoration
        if let mirror = remoteTmuxSessionMirror {
            let selectedPanel = remoteTmuxWindowsPaneId()
                .flatMap { bonsplitController.selectedTab(inPane: $0)?.id }
                .flatMap { panelIdFromSurfaceId($0) }
            snapshot = SessionRemoteTmuxWorkspaceSnapshot(
                destination: mirror.host.destination,
                port: mirror.host.port,
                identityFile: mirror.host.identityFile,
                sessionName: mirror.sessionName,
                selectedWindowId: selectedPanel.flatMap { mirror.windowId(forPanel: $0) }
            )
        }
        let browserURLs = remoteTmuxPreviewURLsByPanelId.compactMap { panelID, source -> (String, String)? in
            guard let browser = panels[panelID] as? BrowserPanel else { return nil }
            let current = browser.preferredURLStringForSessionSnapshot().flatMap(URL.init(string:))
            if source.local.absoluteString == "about:blank",
               current == nil || current?.absoluteString == "about:blank" {
                return (panelID.uuidString, source.remote.absoluteString)
            }
            guard let current, current.scheme == source.local.scheme,
                  current.host == source.local.host, current.port == source.local.port,
                  var restored = URLComponents(url: current, resolvingAgainstBaseURL: false) else { return nil }
            restored.host = source.remote.host
            restored.port = source.remote.port
            return restored.url.map { (panelID.uuidString, $0.absoluteString) }
        }
        snapshot?.browserURLs = browserURLs.isEmpty ? nil : Dictionary(
            uniqueKeysWithValues: browserURLs
        )
        return snapshot
    }

    /// A placeholder uses manual I/O, so a remote snapshot cannot run local commands.
    func restoreRemoteTmuxDisplayPanel(_ snapshot: SessionPanelSnapshot, in pane: PaneID) -> UUID? {
        guard let panel = makeRemoteTmuxPanePanel(onInput: { _ in }),
              let tab = bonsplitController.createTab(
                  title: snapshot.customTitle ?? snapshot.title ?? String(localized: "remoteTmux.tab.pane", defaultValue: "tmux pane"),
                  icon: "rectangle.connected.to.line.below",
                  kind: SurfaceKind.terminal.rawValue,
                  inPane: pane
              ) else { return nil }
        panels[panel.id] = panel
        bindSurface(tab, toPanelId: panel.id)
        applySessionPanelMetadata(snapshot, toPanelId: panel.id)
        return panel.id
    }

    func remoteTmuxBrowserURL(for savedPanelID: UUID) -> URL? {
        guard let raw = remoteTmuxRestoration?.browserURLs?[savedPanelID.uuidString],
              case .loopbackWeb(let url) = RemoteTmuxPreviewTarget(raw: raw, cwd: nil, home: nil) else { return nil }
        return url
    }

    func restoreRemoteTmuxPreviewIdentities(_ remapped: [UUID: UUID]) {
        for (oldID, newID) in remapped {
            guard let remote = remoteTmuxBrowserURL(for: oldID), panels[newID] is BrowserPanel else { continue }
            remoteTmuxPreviewURLsByPanelId[newID] = (remote, URL(string: "about:blank")!)
        }
    }

    /// Starts after the manager has installed the complete restored workspace graph.
    func reconnectRestoredRemoteTmux(using controller: RemoteTmuxController) {
        guard isRemoteTmuxMirror, let saved = remoteTmuxRestoration,
              let host = saved.host, let manager = owningTabManager,
              RemoteTmuxController.isEnabled,
              !managedDevicePolicy.isEnforced(.disableRemoteConnections),
              !isRetiredFromOwningTabManager, remoteTmuxRestoreTask == nil else { return }
        remoteTmuxRestoreTask = Task { @MainActor [weak self, weak manager, weak controller] in
            guard let controller else { return }
            defer { self?.remoteTmuxRestoreTask = nil }
            do {
                try await controller.ensureControlMasterReadyForBurst(host: host)
                guard let self, let manager, !self.isRetiredFromOwningTabManager,
                      !self.managedDevicePolicy.isEnforced(.disableRemoteConnections),
                      manager.tabs.contains(where: { $0 === self }) else { return }
                _ = try controller.mirrorSession(
                    host: host, sessionName: saved.sessionName, into: manager,
                    restoring: self
                )
                if let selected = saved.selectedWindowId,
                   manager.selectedTabId == self.id,
                   self.focusedPanelId.flatMap({ self.panels[$0] }) is TerminalPanel {
                    self.remoteTmuxSessionMirror?.focusWindowWhenAvailable(selected)
                }
                for (panelID, source) in self.remoteTmuxPreviewURLsByPanelId {
                    let local = try await controller.loopbackForwarder.forwardedURL(source.remote, host: host)
                    try Task.checkCancellation()
                    guard !self.isRetiredFromOwningTabManager,
                          let browser = self.panels[panelID] as? BrowserPanel else { continue }
                    self.remoteTmuxPreviewURLsByPanelId[panelID] = (source.remote, local)
                    browser.navigate(to: local)
                }
            } catch {
                if !Task.isCancelled {
                    RemoteTmuxController.logger.warning("remote-tmux session restore could not attach [\(host.connectionHash, privacy: .public)]")
                }
            }
        }
    }
}
