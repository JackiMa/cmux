import Foundation

/// Copies a remote regular file through the existing SSH master without text decoding.
actor RemoteTmuxPreviewFetcher {
    private let maximumBytes: Int64 = 256 * 1_048_576

    func remoteHome(host: RemoteTmuxHost) async throws -> String {
        let output = try await Task.detached(priority: .utility) {
            try Self.runSSH(host: host, command: "printf '%s' \"$HOME\"")
        }.value
        guard let home = String(data: output, encoding: .utf8), home.hasPrefix("/") else {
            throw RemoteTmuxPreviewError.remoteHomeUnavailable
        }
        return home
    }

    func fetch(path: String, cwd: String?, host: RemoteTmuxHost) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try Self.fetchBlocking(path: path, cwd: cwd, host: host, maximumBytes: self.maximumBytes)
        }.value
    }

    private nonisolated static func fetchBlocking(
        path: String, cwd: String?, host: RemoteTmuxHost, maximumBytes: Int64
    ) throws -> URL {
        let remotePath: String
        if path.hasPrefix("/") {
            remotePath = path
        } else if let cwd, cwd.hasPrefix("/") {
            remotePath = cwd + "/" + path
        } else {
            throw RemoteTmuxPreviewError.remoteDirectoryUnavailable
        }
        // Resolve once against the remote pane. An absolute path must not
        // depend on an unrelated cwd still existing, or on remote Python.
        let quotedPath = RemoteTmuxHost.shellSingleQuoted(remotePath)
        let resolve = "p=\(quotedPath); [ -f \"$p\" ] || exit 5; "
        let metadata = try runSSH(host: host, command: resolve + "wc -c < \"$p\"")
        guard let size = Int64(String(decoding: metadata, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw RemoteTmuxPreviewError.remoteFileUnavailable
        }
        guard size <= maximumBytes else { throw RemoteTmuxPreviewError.fileTooLarge }

        let filename = (path as NSString).lastPathComponent
        let safeName = filename.map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-" || character == "_"
                ? character : "_"
        }
        let basename = String(safeName).isEmpty ? "preview" : String(safeName)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-preview", isDirectory: true)
            .appendingPathComponent(host.connectionHash, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(basename)")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        do {
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: RemoteTmuxHost.defaultSSHExecutablePath())
            process.arguments = RemoteTmuxPreviewSSHOptions(host: host).arguments + ["--", host.destination, resolve + "cat -- \"$p\""]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            stdout.fileHandleForWriting.closeFile()
            stderr.fileHandleForWriting.closeFile()
            var received: Int64 = 0
            while true {
                let chunk = stdout.fileHandleForReading.readData(ofLength: 64 * 1024)
                if chunk.isEmpty { break }
                received += Int64(chunk.count)
                if received > maximumBytes {
                    process.terminate()
                    process.waitUntilExit()
                    throw RemoteTmuxPreviewError.fileTooLarge
                }
                try output.write(contentsOf: chunk)
            }
            process.waitUntilExit()
            let detail = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                throw (detail.isEmpty ? RemoteTmuxPreviewError.remoteFileUnavailable : RemoteTmuxPreviewError.remoteDetail(String(detail.prefix(200))))
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private nonisolated static func runSSH(host: RemoteTmuxHost, command: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: RemoteTmuxHost.defaultSSHExecutablePath())
        process.arguments = RemoteTmuxPreviewSSHOptions(host: host).arguments + ["--", host.destination, command]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        stdout.fileHandleForWriting.closeFile()
        stderr.fileHandleForWriting.closeFile()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let detail = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw (detail.isEmpty ? RemoteTmuxPreviewError.remoteFileUnavailable : RemoteTmuxPreviewError.remoteDetail(String(detail.prefix(200))))
        }
        return data
    }

}
