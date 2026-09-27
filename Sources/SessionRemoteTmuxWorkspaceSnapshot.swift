import Foundation

/// Reconnects an existing remote session without persisting a local launch command.
struct SessionRemoteTmuxWorkspaceSnapshot: Codable, Sendable, Equatable {
    var destination: String
    var port: Int?
    var identityFile: String?
    var sessionName: String
    var selectedWindowId: Int? = nil
    var browserURLs: [String: String]? = nil

    var host: RemoteTmuxHost? {
        guard !destination.isEmpty, !destination.hasPrefix("-"),
              !destination.contains(where: { $0.isWhitespace || $0 == "\0" }),
              port.map({ (1...65535).contains($0) }) ?? true,
              !sessionName.isEmpty,
              RemoteTmuxHost.controlModeLineSafeName(sessionName) != nil,
              identityFile?.contains("\0") != true else { return nil }
        return RemoteTmuxHost(destination: destination, port: port, identityFile: identityFile)
    }
}
