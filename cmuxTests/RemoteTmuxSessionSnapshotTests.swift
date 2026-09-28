import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized) struct RemoteTmuxSessionSnapshotTests {
    @Test func connectedMirrorSurvivesTheAppSnapshotRoundTrip() throws {
        let previous = AppDelegate.shared
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let host = RemoteTmuxHost(destination: "cmux-restore-test.invalid", port: 2222, identityFile: "/tmp/cmux-restore-test-key")
        let connection = RemoteTmuxControlConnection(host: host, sessionName: "agents")
        delegate.remoteTmuxController.cacheConnection(connection)
        _ = try delegate.remoteTmuxController.mirrorSession(host: host, sessionName: "agents", into: manager)
        let remote = try #require(manager.tabs.first { $0.isRemoteTmuxMirror })
        manager.selectWorkspace(remote)
        let window = delegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            delegate.remoteTmuxController.detachAll()
            delegate.unregisterMainWindowContextForTesting(windowId: window)
            AppDelegate.shared = previous
        }

        let saved = try #require(delegate.sessionSnapshotForTesting())
        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: JSONEncoder().encode(saved))
        let restoredManager = try #require(decoded.windows.first?.tabManager)
        #expect(restoredManager.workspaces.contains { $0.workspaceId == remote.id })
        #expect(restoredManager.selectedWorkspaceIndex == 1)
        let remoteSnapshot = try #require(restoredManager.workspaces.first { $0.workspaceId == remote.id })
        #expect(remoteSnapshot.remoteTmux?.host == host)
        #expect(remoteSnapshot.remoteTmux?.sessionName == "agents")
        if let local = manager.tabs.first(where: { !$0.isRemoteTmuxMirror }) {
            manager.closeWorkspace(local, recordHistory: false)
        }
        let remoteOnly = try #require(delegate.sessionSnapshotForTesting())
        #expect(remoteOnly.windows[0].tabManager.workspaces.map(\.workspaceId) == [remote.id])
    }

    @Test func savedRemoteTerminalsRestoreAsProcessFreeDisplays() throws {
        let source = Workspace(title: "agents", portOrdinal: 0)
        var snapshot = source.sessionSnapshot(includeScrollback: false)
        snapshot.panels[0].terminal?.tmuxStartCommand = "printf LOCAL_RESTORE_FORBIDDEN"
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        encoded["remoteTmux"] = [
            "destination": "cmux-restore-test.invalid", "port": 2222,
            "identityFile": "/tmp/cmux-restore-test-key", "sessionName": "agents"
        ]
        snapshot = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: encoded))
        let restored = Workspace(title: "restore", portOrdinal: 1)
        _ = restored.restoreSessionSnapshot(snapshot)

        #expect(restored.isRemoteTmuxMirror)
        let terminals = restored.panels.values.compactMap { $0 as? TerminalPanel }
        #expect(!terminals.isEmpty)
        #expect(terminals.allSatisfy { $0.surface.ioMode == .manualMirror })
        #expect(terminals.allSatisfy { $0.surface.debugTmuxStartCommand() == nil })
    }

    @Test func reattachReusesSavedWorkspaceAndRetainsPreviewPane() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let source = Workspace(title: "agents", portOrdinal: 1)
        let terminal = try #require(source.focusedPanelId)
        let browser = try #require(source.newBrowserSplit(
            from: terminal, orientation: .horizontal, url: URL(string: "about:blank"), focus: false
        ))
        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let host = RemoteTmuxHost(destination: "cmux-restore-test.invalid")
        snapshot.remoteTmux = SessionRemoteTmuxWorkspaceSnapshot(
            destination: host.destination, sessionName: "agents",
            browserURLs: [browser.id.uuidString: "http://127.0.0.1:6013/#scalars"]
        )
        let remapped = workspace.restoreSessionSnapshot(snapshot)
        let restoredBrowser = try #require(remapped[browser.id].flatMap { workspace.panels[$0] as? BrowserPanel })
        #expect(workspace.bonsplitController.allPaneIds.count == 2)
        #expect(workspace.remoteTmuxPreviewURLsByPanelId[restoredBrowser.id]?.remote.absoluteString == "http://127.0.0.1:6013/#scalars")

        let controller = RemoteTmuxController()
        let connection = RemoteTmuxControlConnection(host: host, sessionName: "agents")
        controller.cacheConnection(connection)
        defer { controller.detachAll() }
        #expect(try controller.mirrorSession(host: host, sessionName: "agents", into: manager, restoring: workspace))
        #expect(manager.tabs.count == 1)
        #expect(controller.sessionMirror(host: host, sessionName: "agents")?.mirroredWorkspace === workspace)
        #expect(workspace.panels[restoredBrowser.id] === restoredBrowser)
        #expect(!controller.mirrorDiscoveredSessions(
            host: host, sessions: [], into: manager
        ).isEmpty)
    }

    @Test func invalidRemoteAttachmentNeverBecomesALocalLaunch() throws {
        let workspace = Workspace(title: "invalid remote", portOrdinal: 0)
        var snapshot = workspace.sessionSnapshot(includeScrollback: false)
        snapshot.remoteTmux = SessionRemoteTmuxWorkspaceSnapshot(destination: "-oProxyCommand=invalid", sessionName: "agents")
        snapshot.panels[0].terminal?.tmuxStartCommand = "printf LOCAL_RESTORE_FORBIDDEN"
        _ = workspace.restoreSessionSnapshot(snapshot)
        #expect(snapshot.remoteTmux?.host == nil)
        #expect(workspace.isRemoteTmuxMirror)
        #expect(workspace.panels.values.compactMap { $0 as? TerminalPanel }.allSatisfy { $0.surface.ioMode == .manualMirror })
    }

    @Test func sessionSnapshotSkipsWindowWithOnlyRemoteTmuxMirrorWorkspaces() throws {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        workspace.isRemoteTmuxMirror = true
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            AppDelegate.shared = originalAppDelegate
        }

        #expect(appDelegate.sessionSnapshotForTesting() == nil)
    }

    @Test func sessionSnapshotPreservesLocalWorkspaceInWindowWithRemoteTmuxMirror() throws {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let localWorkspace = try #require(manager.selectedWorkspace)
        localWorkspace.setCustomTitle("Local")
        let remoteWorkspace = manager.addWorkspace(
            title: "remote",
            select: true,
            autoWelcomeIfNeeded: false
        )
        remoteWorkspace.isRemoteTmuxMirror = true
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            AppDelegate.shared = originalAppDelegate
        }

        let snapshot = try #require(appDelegate.sessionSnapshotForTesting())
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].tabManager.workspaces.map(\.workspaceId) == [localWorkspace.id])
        #expect(snapshot.windows[0].tabManager.selectedWorkspaceIndex == nil)
    }

    @Test func autosaveProjectionUsesTheSameEligibleRoutesAsSessionSnapshot() throws {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        let remoteOnlyWindowId = try #require(
            UUID(uuidString: "00000000-0000-4000-8000-000000000001")
        )
        let persistedWindowId = try #require(
            UUID(uuidString: "00000000-0000-4000-8000-000000000002")
        )
        let remoteOnlyManager = TabManager(autoWelcomeIfNeeded: false)
        let remoteOnlyWorkspace = try #require(remoteOnlyManager.selectedWorkspace)
        remoteOnlyWorkspace.isRemoteTmuxMirror = true
        let persistedManager = TabManager(autoWelcomeIfNeeded: false)
        appDelegate.registerMainWindowContextForTesting(
            windowId: remoteOnlyWindowId,
            tabManager: remoteOnlyManager
        )
        appDelegate.registerMainWindowContextForTesting(
            windowId: persistedWindowId,
            tabManager: persistedManager
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: remoteOnlyWindowId)
            appDelegate.unregisterMainWindowContextForTesting(windowId: persistedWindowId)
            AppDelegate.shared = originalAppDelegate
        }

        let eligibleRoutes = appDelegate.orderedSessionRouteSnapshots()
        let projection = MainWindowRouteAutosaveProjection(
            orderedWindowIds: eligibleRoutes.map(\.windowId),
            previouslyPersistedWindowIds: [],
            maximumFingerprintWindows: 1
        )
        let snapshot = try #require(appDelegate.sessionSnapshotForTesting())

        #expect(eligibleRoutes.map(\.windowId) == [persistedWindowId])
        #expect(projection.fingerprintWindowIds == [persistedWindowId])
        #expect(snapshot.windows.compactMap(\.windowId) == [persistedWindowId])
    }
}
