import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Remote tmux preview routing", .serialized)
struct RemoteTmuxPreviewRoutingTests {
    @Test func terminalLinksShareAPreviewPaneOutsideTheTmuxWindows() throws {
        let harness = try RemoteTmuxMirrorCLIObservabilityTests.Harness(connectedTransport: true)
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let source = try #require(harness.mirror.panel(forPane: 11))
        let terminalPane = try #require(workspace.paneId(forPanelId: harness.outerPanelID))
        let originalTabs = workspace.bonsplitController.tabs(inPane: terminalPane).map(\.id)
        let originalFocus = workspace.focusedPanelId
        let originalMirrorPanes = harness.mirror.paneIDsInOrder

        #expect(workspace.openTerminalBrowserLink(
            url: URL(string: "http://127.0.0.1:6013/")!, sourcePanelId: source.id, focus: false
        ))
        #expect(workspace.openTerminalBrowserLink(
            url: URL(string: "http://127.0.0.1:6013/#scalars")!, sourcePanelId: source.id, focus: false
        ))

        let browsers = workspace.panels.values.compactMap { $0 as? BrowserPanel }
        #expect(browsers.count == 2)
        #expect(workspace.bonsplitController.allPaneIds.count == 2)
        #expect(workspace.bonsplitController.tabs(inPane: terminalPane).map(\.id) == originalTabs)
        #expect(workspace.focusedPanelId == originalFocus)
        #expect(harness.mirror.paneIDsInOrder == originalMirrorPanes)
        let previewPane = try #require(browsers.first.flatMap { workspace.paneId(forPanelId: $0.id) })
        #expect(previewPane != terminalPane)
        #expect(browsers.allSatisfy { workspace.paneId(forPanelId: $0.id) == previewPane })

        // A remote window arriving while a preview is focused must stay in the
        // tmux tab strip. Preview tabs also reorder locally, without tmux RPCs.
        workspace.bonsplitController.focusPane(previewPane)
        let nextWindow = try #require(workspace.addRemoteTmuxDisplayPane(
            remotePaneId: 99, title: "next window", onInput: { _ in }
        ))
        #expect(workspace.paneId(forPanelId: nextWindow.id) == terminalPane)
        #expect(workspace.reorderSurface(panelId: browsers[0].id, toIndex: 1, focus: false))
        workspace.setPanelPinned(panelId: browsers[0].id, pinned: true)
        #expect(workspace.isPanelPinned(browsers[0].id))
        let remoteTab = try #require(workspace.surfaceIdFromPanelId(nextWindow.id))
        #expect(!workspace.bonsplitController.moveTab(remoteTab, toPane: previewPane))
        #expect(!workspace.splitTabBar(
            workspace.bonsplitController, shouldSplitPane: terminalPane, orientation: .horizontal
        ))
    }

    @Test func browserCreationEntryPointsKeepTheTmuxStripAndCanReopenAfterClose() throws {
        let harness = try RemoteTmuxMirrorCLIObservabilityTests.Harness()
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let terminalPane = try #require(workspace.paneId(forPanelId: harness.outerPanelID))
        let first = try #require(workspace.newBrowserSurface(
            inPane: terminalPane, url: URL(string: "about:blank"), focus: false
        ))
        #expect(workspace.paneId(forPanelId: first.id) != terminalPane)
        #expect(workspace.closePanel(first.id, force: true))
        #expect(workspace.bonsplitController.allPaneIds.count == 1)
        let second = try #require(workspace.newBrowserSplit(
            from: harness.outerPanelID, orientation: .horizontal,
            url: URL(string: "about:blank"), focus: false
        ))
        #expect(workspace.paneId(forPanelId: second.id) != terminalPane)
        #expect(workspace.bonsplitController.allPaneIds.count == 2)
    }

    @Test func downloadedImagePreviewDoesNotRequestATmuxSplit() throws {
        let harness = try RemoteTmuxMirrorCLIObservabilityTests.Harness(connectedTransport: true)
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let terminalPane = try #require(workspace.paneId(forPanelId: harness.outerPanelID))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tmux-preview-\(UUID()).png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a2ioAAAAASUVORK5CYII=")!.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let preview = workspace.splitPaneWithFilePreview(
            targetPane: terminalPane, orientation: .horizontal, insertFirst: false, filePath: file.path
        )
        #expect(preview != nil)
        #expect(workspace.bonsplitController.allPaneIds.count == 2)
        #expect(workspace.paneId(forPanelId: harness.outerPanelID) == terminalPane)
        if let preview { #expect(workspace.paneId(forPanelId: preview.id) != terminalPane) }
        let writer = try #require(harness.controlWriter)
        writer.close()
        let pipe = try #require(harness.controlPipe)
        let commands = String(decoding: try pipe.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
        #expect(!commands.split(separator: "\n").contains { $0.hasPrefix("split-window ") })
    }

    @Test func relativeFileUsesItsOwnRemotePaneDirectory() throws {
        let harness = try RemoteTmuxMirrorCLIObservabilityTests.Harness()
        defer { harness.tearDown() }
        harness.mirror.updatePaneCwd(paneId: 11, path: "/srv/artifacts/run")
        harness.mirror.updatePaneCwd(paneId: 22, path: "/srv/other")
        let source = try #require(harness.mirror.panel(forPane: 11))
        let context = try #require(harness.workspace.remoteTmuxPreviewContext(for: source.id))
        #expect(RemoteTmuxPreviewTarget(
            raw: "visuals_20260927_1630/getup_9250_frames.png", cwd: context.cwd, home: nil
        ) == .remoteFile(absolutePOSIXPath: "/srv/artifacts/run/visuals_20260927_1630/getup_9250_frames.png"))
    }
}
