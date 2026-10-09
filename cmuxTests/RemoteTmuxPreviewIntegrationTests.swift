import CryptoKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Opt-in live SSH verification. The fixture contains connection coordinates and
/// expected artifact metadata, never credentials. Session-creating checks own
/// their fixtures; the busy-master probe only reads an existing connection.
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
        .enabled(if: ProcessInfo.processInfo.environment["CMUX_LIVE_PTMUX_BUSY_FIXTURE"] != nil),
        .timeLimit(.minutes(1))
    )
    func saturatedExistingMasterStillReadsTheRealImage() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["CMUX_LIVE_PTMUX_BUSY_FIXTURE"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let host = RemoteTmuxHost(destination: fixture.destination, port: fixture.port, identityFile: fixture.identityFile)
        // Read-only opt-in probe of an already busy master. Do not attach,
        // detach, or close it: the live terminal sessions belong to the user.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: RemoteTmuxHost.defaultSSHExecutablePath())
        probe.arguments = RemoteTmuxPreviewSSHOptions(host: host).arguments + ["--", host.destination, "true"]
        let stderr = Pipe()
        probe.standardInput = FileHandle.nullDevice
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = stderr
        try probe.run()
        stderr.fileHandleForWriting.closeFile()
        let detail = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        probe.waitUntilExit()
        try #require(probe.terminationStatus == 255)
        try #require(detail.contains("Session open refused by peer"))

        let fetcher = RemoteTmuxPreviewFetcher()
        let directory = (fixture.imagePath as NSString).deletingLastPathComponent
        let filename = (fixture.imagePath as NSString).lastPathComponent
        for (path, cwd) in [(fixture.imagePath, "/absent-directory"), (filename, directory)] {
            let downloaded = try await fetcher.fetch(path: path, cwd: cwd, host: host)
            defer { try? FileManager.default.removeItem(at: downloaded) }
            #expect(SHA256.hash(data: try Data(contentsOf: downloaded))
                .map { String(format: "%02x", $0) }.joined() == fixture.imageSHA256)
        }
        #expect(try await fetcher.remoteHome(host: host).hasPrefix("/"))
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

        let imageDirectory = (fixture.imagePath as NSString).deletingLastPathComponent
        let created = try await transport.runTmux([
            "new-session", "-d", "-s", session, "-c", imageDirectory, "sleep 90"
        ])
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
        // An absolute path must still download when a pane's cached cwd no
        // longer exists. Exercise the real SSH command, before opening a UI.
        let missingDirectory = "/__cmux_preview_missing_\(UUID().uuidString)"
        let downloaded = try await controller.previewFetcher.fetch(
            path: fixture.imagePath, cwd: missingDirectory, host: host
        )
        defer { try? FileManager.default.removeItem(at: downloaded) }
        #expect(SHA256.hash(data: try Data(contentsOf: downloaded))
            .map { String(format: "%02x", $0) }.joined() == fixture.imageSHA256)

        let location = try #require(workspace.remoteTmuxControlPane(surfaceID: source))
        let windowMirror = try #require(location.windowMirror)
        windowMirror.updatePaneCwd(paneId: location.pane.tmuxPaneID, path: missingDirectory)
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

        // Click immediately after a remote cd, before the directory cache has
        // caught up, and also before the first directory report has arrived.
        let filename = (fixture.imagePath as NSString).lastPathComponent
        for cachedDirectory in [missingDirectory, nil] as [String?] {
            windowMirror.cwdByPaneId[location.pane.tmuxPaneID] = cachedDirectory
            #expect(TerminalLinkOpenCoordinator().open(TerminalLinkOpenRequest(
                rawValue: "./" + filename, sourceWorkspaceId: workspace.id,
                sourcePanelId: source, workingDirectory: "/unrelated/local/directory", focus: false
            )))
            let relativeID = try await nextCreatedSurface(in: workspace, subscription: subscription, kind: "file_preview")
            let relativeImage = try #require(workspace.panels[relativeID] as? FilePreviewPanel)
            #expect(SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: relativeImage.filePath)))
                .map { String(format: "%02x", $0) }.joined() == fixture.imageSHA256)
            #expect(workspace.paneId(forPanelId: relativeID) == workspace.paneId(forPanelId: imageID))
        }

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
