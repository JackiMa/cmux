import Darwin
import Foundation

/// Reuses a loopback TCP listener for each remote host and web port.
actor RemoteTmuxLoopbackForwarder {
    private struct Key: Hashable {
        let connectionHash: String
        let remotePort: Int
    }
    private struct Listener {
        let fd: Int32
        let localPort: Int
        let task: Task<Void, Never>
    }
    private var listeners: [Key: Listener] = [:]

    func forwardedURL(_ remoteURL: URL, host: RemoteTmuxHost) async throws -> URL {
        guard let port = remoteURL.port, (1...65535).contains(port) else {
            throw RemoteTmuxPreviewError.invalidLink
        }
        guard await Task.detached(priority: .utility, operation: {
            Self.masterIsRunning(host: host)
        }).value else {
            throw RemoteTmuxPreviewError.connectionUnavailable
        }
        let key = Key(connectionHash: host.connectionHash, remotePort: port)
        let localPort: Int
        if let listener = listeners[key] {
            localPort = listener.localPort
        } else {
            let (fd, assignedPort) = try Self.makeListener()
            let task = Task.detached(priority: .utility) {
                while true {
                    var address = sockaddr()
                    var size = socklen_t(MemoryLayout<sockaddr>.size)
                    let client = withUnsafeMutablePointer(to: &address) {
                        Darwin.accept(fd, $0, &size)
                    }
                    if client < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    Task.detached(priority: .utility) {
                        await Self.relay(client: client, host: host, remotePort: port)
                    }
                }
            }
            listeners[key] = Listener(fd: fd, localPort: assignedPort, task: task)
            localPort = assignedPort
        }
        var components = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false)
        components?.host = "127.0.0.1"
        components?.port = localPort
        guard let localURL = components?.url else { throw RemoteTmuxPreviewError.invalidLink }
        return localURL
    }

    private nonisolated static func makeListener() throws -> (Int32, Int) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RemoteTmuxPreviewError.forwardUnavailable }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 32) == 0 else {
            Darwin.close(fd)
            throw RemoteTmuxPreviewError.forwardUnavailable
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(fd)
            throw RemoteTmuxPreviewError.forwardUnavailable
        }
        return (fd, Int(UInt16(bigEndian: address.sin_port)))
    }

    private nonisolated static func masterIsRunning(host: RemoteTmuxHost) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: RemoteTmuxHost.defaultSSHExecutablePath())
        process.arguments = ["-O", "check", "-o", "ControlPath=\(host.controlSocketPath)",
                             "-o", "BatchMode=yes", "--", host.destination]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { return false }
        return process.terminationStatus == 0
    }

    private nonisolated static func relay(client: Int32, host: RemoteTmuxHost, remotePort: Int) async {
        defer { Darwin.close(client) }
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            Darwin.setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: RemoteTmuxHost.defaultSSHExecutablePath())
        process.arguments = RemoteTmuxPreviewSSHOptions(host: host).arguments
            + ["-W", "127.0.0.1:\(remotePort)", "--", host.destination]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return }
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        let inputFD = input.fileHandleForWriting.fileDescriptor
        let outputFD = output.fileHandleForReading.fileDescriptor
        _ = Darwin.fcntl(inputFD, F_SETNOSIGPIPE, 1)
        let upstream = Task.detached(priority: .utility) {
            Self.copy(from: client, to: inputFD, toSocket: false)
            input.fileHandleForWriting.closeFile()
        }
        let downstream = Task.detached(priority: .utility) {
            Self.copy(from: outputFD, to: client, toSocket: true)
            _ = Darwin.shutdown(client, SHUT_WR)
        }
        await downstream.value
        _ = Darwin.shutdown(client, SHUT_RD)
        await upstream.value
        process.waitUntilExit()
    }

    private nonisolated static func copy(from source: Int32, to destination: Int32, toSocket: Bool) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(source, $0.baseAddress!, $0.count)
            }
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { bytes -> Int in
                    let pointer = bytes.baseAddress!.advanced(by: offset)
                    return toSocket
                        ? Darwin.send(destination, pointer, count - offset, 0)
                        : Darwin.write(destination, pointer, count - offset)
                }
                if written < 0 && errno == EINTR { continue }
                if written <= 0 { return }
                offset += written
            }
        }
    }

}
