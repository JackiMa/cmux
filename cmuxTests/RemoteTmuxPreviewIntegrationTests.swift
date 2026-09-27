import CryptoKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Opt-in live SSH verification. The fixture contains connection coordinates and
/// expected artifact metadata, never credentials. Each run owns its tmux session.
@MainActor
@Suite(.serialized)
struct RemoteTmuxPreviewIntegrationTests {
    private struct Fixture: Decodable {
        var destination: String
        var port: Int?
        var identityFile: String?
        var imagePath: String
        var imageSHA256: String
        var webURL: String
        var pageMarker: String
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["CMUX_LIVE_PTMUX_FIXTURE"] != nil),
        .timeLimit(.minutes(1))
    )
    func terminalLinkRequestsFetchTheRealImageAndForwardTheRealWebService() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["CMUX_LIVE_PTMUX_FIXTURE"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let host = RemoteTmuxHost(destination: fixture.destination, port: fixture.port, identityFile: fixture.identityFile)
        let session = "cmux-preview-check-\(UUID().uuidString.lowercased())"
        let previous = AppDelegate.shared
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let window = delegate.registerMainWindowContextForTesting(tabManager: manager)
        let controller = delegate.remoteTmuxController
        let transport = controller.transport(for: host)
        defer {
            controller.detachAll()
            delegate.unregisterMainWindowContextForTesting(windowId: window)
            AppDelegate.shared = previous
        }

        let created = try await transport.runTmux(["new-session", "-d", "-s", session, "sleep 90"])
        try #require(created.exitCode == 0)
        do {
            try await verifyLinks(fixture: fixture, host: host, session: session, manager: manager, controller: controller)
        } catch {
            _ = try? await transport.runTmux(["kill-session", "-t", "=\(session)"])
            throw error
        }
        let cleaned = try await transport.runTmux(["kill-session", "-t", "=\(session)"])
        #expect(cleaned.exitCode == 0)
    }

    private func verifyLinks(
        fixture: Fixture, host: RemoteTmuxHost, session: String,
        manager: TabManager, controller: RemoteTmuxController
    ) async throws {
        try await controller.ensureControlMasterReadyForBurst(host: host)
        try #require(try controller.mirrorSession(host: host, sessionName: session, into: manager))
        let mirror = try #require(controller.sessionMirror(host: host, sessionName: session))
        let workspace = try #require(mirror.mirroredWorkspace)
        let connection = mirror.connection
        let (changes, continuation) = AsyncStream<Void>.makeStream()
        let observer = connection.addObserver(
            onTopologyChanged: { continuation.yield(()) },
            onExit: { continuation.finish() }
        )
        defer { connection.removeObserver(observer); continuation.finish() }
        try #require(await connection.waitUntilConnected())
        if mirror.paneSurfaceEntries().isEmpty {
            for await _ in changes where !mirror.paneSurfaceEntries().isEmpty { break }
        }
        let entry = try #require(mirror.paneSurfaceEntries().first)
        let source = try #require((entry["surface_id"] as? String).flatMap(UUID.init(uuidString:)))
        let terminalPane = try #require(workspace.remoteTmuxWindowsPaneId())
        let initialWindows = connection.windowOrder
        let subscription = CmuxEventBus.shared.subscribe(afterSequence: nil, names: ["surface.created"], categories: []).subscription
        defer { CmuxEventBus.shared.unsubscribe(subscription) }

        #expect(TerminalLinkOpenCoordinator().open(TerminalLinkOpenRequest(
            rawValue: fixture.imagePath, sourceWorkspaceId: workspace.id,
            sourcePanelId: source, workingDirectory: nil, focus: false
        )))
        let imageID = try await nextCreatedSurface(in: workspace, subscription: subscription, kind: "file_preview")
        let image = try #require(workspace.panels[imageID] as? FilePreviewPanel)
        let data = try Data(contentsOf: URL(fileURLWithPath: image.filePath))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == fixture.imageSHA256)
        #expect(workspace.paneId(forPanelId: imageID) != terminalPane)

        #expect(TerminalLinkOpenCoordinator().open(TerminalLinkOpenRequest(
            rawValue: fixture.webURL, sourceWorkspaceId: workspace.id,
            sourcePanelId: source, workingDirectory: nil, focus: false
        )))
        let browserID = try await nextCreatedSurface(in: workspace, subscription: subscription, kind: "browser")
        let mapping = try #require(workspace.remoteTmuxPreviewURLsByPanelId[browserID])
        #expect(mapping.remote.absoluteString == fixture.webURL)
        let (html, response) = try await URLSession.shared.data(from: mapping.local)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: html, as: UTF8.self).contains(fixture.pageMarker))
        #expect(workspace.paneId(forPanelId: imageID) == workspace.paneId(forPanelId: browserID))
        #expect(workspace.bonsplitController.allPaneIds.count == 2)
        #expect(connection.windowOrder == initialWindows)
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.remoteTmux?.browserURLs?[browserID.uuidString] == fixture.webURL)
    }

    private func nextCreatedSurface(
        in workspace: Workspace, subscription: CmuxEventSubscription, kind: String
    ) async throws -> UUID {
        while let event = await subscription.nextAsync() {
            guard event["workspace_id"] as? String == workspace.id.uuidString,
                  let payload = event["payload"] as? [String: Any], payload["kind"] as? String == kind,
                  let id = (event["surface_id"] as? String).flatMap(UUID.init(uuidString:)) else { continue }
            return id
        }
        throw NSError(domain: "RemoteTmuxPreviewIntegrationTests", code: 1)
    }
}
