import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Runs the production sizing commands against an isolated real tmux server.
/// CMUX_LEGACY_SIZING_TMUX may point at a tmux executable or an SSH adapter
/// forwarding its argv to an older server binary. Every process uses a unique
/// socket, so even the remote variant cannot resize or stop a user's sessions.
@MainActor
@Suite(.serialized)
struct RemoteTmuxLegacySizingTests {
    nonisolated private static var executable: String? {
        ProcessInfo.processInfo.environment["CMUX_LEGACY_SIZING_TMUX"]
            ?? ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @Test(.enabled(if: executable != nil), .timeLimit(.minutes(1)))
    func latestInteractionOwnsSizeWithoutBackgroundReplayStealingIt() async throws {
        let executable = try #require(Self.executable)
        let prefix = ["-L", "cmux-sizing-\(UUID().uuidString.lowercased())", "-f", "/dev/null"]
        func tmux(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = prefix + arguments
            process.standardInput = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            output.fileHandleForWriting.closeFile()
            let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            try #require(process.terminationStatus == 0, "\(arguments): \(result)")
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func width(_ window: Int) throws -> String {
            try tmux(["display-message", "-p", "-t", "@\(window)", "#{window_width}"])
        }

        print("Latest interaction sizing fixture: \(try tmux(["-V"]))")
        _ = try tmux(["new-session", "-d", "-s", "sizing", "-x", "188", "-y", "50", "sleep 90"])
        defer { _ = try? tmux(["kill-server"]) }
        _ = try tmux(["set-option", "-g", "window-size", "latest"])
        let first = try #require(Int(try tmux(["display-message", "-p", "-t", "sizing", "#{window_id}"]).dropFirst()))
        let second = try #require(Int(try tmux(["new-window", "-d", "-P", "-F", "#{window_id}", "-t", "sizing", "sleep 90"]).dropFirst()))
        let client = try Client(executable: executable, arguments: prefix)
        defer { client.stop() }
        try await client.ready()
        let peer = try Client(executable: executable, arguments: prefix)
        defer { peer.stop() }
        try await peer.ready()
        peer.connection.setClientSize(columns: 188, rows: 50)
        await peer.connection.clientSizeDebounceTask?.value
        try await peer.command("select-window -t @\(first)")
        try await peer.command("refresh-client -C 188x50")
        try #require(try width(first) == "188")

        client.connection.setWindowSize(windowId: second, columns: 99, rows: 36)
        client.connection.setWindowSize(windowId: first, columns: 139, rows: 36)
        client.connection.notePerWindowSizeRejected()
        await client.connection.clientSizeDebounceTask?.value
        try await client.fence()
        #expect(client.connection.windowSizeDebounceTasks.isEmpty)
        // Attach, hidden geometry and capability fallback are not user actions.
        #expect(try width(first) == "188")
        #expect(try tmux(["show-options", "-w", "-v", "-t", "@\(first)", "window-size"]) == "latest")

        let firstPane = try #require(Int(try tmux(["display-message", "-p", "-t", "@\(first)", "#{pane_id}"]).dropFirst()))
        let secondPane = try #require(Int(try tmux(["display-message", "-p", "-t", "@\(second)", "#{pane_id}"]).dropFirst()))
        for (pane, window, columns) in [(firstPane, first, 139), (secondPane, second, 99), (firstPane, first, 139)] {
            #expect(client.connection.sendKeys(paneId: pane, data: Data("x".utf8)))
            try await client.fence()
            #expect(try width(window) == String(columns))
            #expect(try tmux(["display-message", "-p", "-t", "sizing", "#{window_id}"]) == "@\(window)")
        }

        // A wide peer must reclaim the full grid even while cmux stays attached.
        try await peer.command("select-window -t @\(first)")
        try await peer.command("refresh-client -C 188x50")
        try await client.fence()
        #expect(try width(first) == "188")
        client.connection.replayRecordedSizeClaims()
        client.connection.setWindowSize(windowId: first, columns: 120, rows: 36)
        await client.connection.clientSizeDebounceTask?.value
        try await client.fence()
        #expect(try width(first) == "188", "Background replay/geometry must not reclaim ownership")
        #expect(client.connection.sendKey(paneId: firstPane, key: RemoteTmuxKeyName(rawName: "Enter")!))
        try await client.fence()
        #expect(try width(first) == "120")

        try await peer.command("select-window -t @\(first)")
        try await peer.command("refresh-client -C 188x50")
        try await client.command("detach-client")
        try await peer.fence()
        #expect(try width(first) == "188")
        #expect(try tmux(["show-options", "-g", "-v", "window-size"]) == "latest")
    }

    @MainActor
    private final class Client {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "sizing-fixture"), sessionName: "sizing"
        )
        private let process = Process()
        private let writer: RemoteTmuxControlPipeWriter
        private let reader: RemoteTmuxProcessOutputReader
        private var readTask: Task<Void, Never>?
        private let topology: AsyncStream<Void>
        private let topologyContinuation: AsyncStream<Void>.Continuation

        init(executable: String, arguments: [String]) throws {
            let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            topology = stream.stream
            topologyContinuation = stream.continuation
            let input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments + ["-C", "attach-session", "-t", "sizing"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            writer = RemoteTmuxControlPipeWriter(
                handle: input.fileHandleForWriting, label: "legacy-sizing-test-input",
                maxPendingBytes: 1 << 20, onFailure: {}
            )
            reader = RemoteTmuxProcessOutputReader(
                label: "legacy-sizing-test-output", maxPendingChunks: 128,
                maxPendingBytes: 1 << 20, onOverflow: {}
            )
            connection.installStdinWriterForTesting(writer)
            connection.handleMessageForTesting(.enter)
            connection.pendingAttachRedrawKick = false
            _ = connection.addObserver(onTopologyChanged: { stream.continuation.yield(()) })
            try process.run()
            output.fileHandleForWriting.closeFile()
            input.fileHandleForReading.closeFile()
            reader.attach(to: output.fileHandleForReading)
            readTask = Task { [connection, reader] in
                var parser = RemoteTmuxControlStreamParser()
                for await data in reader.stream {
                    for message in parser.feed(data) { connection.handleMessageForTesting(message) }
                    reader.release(data)
                }
            }
        }

        func ready() async throws {
            if connection.windowsByID.isEmpty {
                for await _ in topology where !connection.windowsByID.isEmpty { break }
            }
            try #require(!connection.windowsByID.isEmpty)
            try await fence()
        }

        func command(_ text: String) async throws {
            let succeeded = await withCheckedContinuation { continuation in
                if !connection.sendTracked(text, completion: { continuation.resume(returning: $0) }) {
                    continuation.resume(returning: false)
                }
            }
            try #require(succeeded, "tmux command failed: \(text)")
        }

        func fence() async throws {
            try await command("display-message -p cmux-sizing-fence")
        }

        func stop() {
            connection.stop()
            writer.close()
            reader.close()
            readTask?.cancel()
            topologyContinuation.finish()
            if process.isRunning { process.terminate() }
        }
    }
}
