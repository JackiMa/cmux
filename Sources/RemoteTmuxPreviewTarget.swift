import Foundation

/// Classifies a clicked tmux link using only remote path context.
enum RemoteTmuxPreviewTarget: Equatable {
    case remoteFile(absolutePOSIXPath: String)
    case loopbackWeb(URL)
    case publicWeb(URL)
    case needsRemoteDirectory
    case needsRemoteHome
    case invalid

    init(raw: String, cwd: String?, home: String?) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty,
              !text.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) else {
            self = .invalid
            return
        }

        if let url = URL(string: text),
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            guard var components = URLComponents(string: text), let host = components.host?.lowercased(),
                  !host.isEmpty else {
                self = .invalid
                return
            }
            if ["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"].contains(host) {
                components.host = "127.0.0.1"
                components.port = components.port ?? (scheme == "http" ? 80 : 443)
                guard let normalized = components.url else { self = .invalid; return }
                self = .loopbackWeb(normalized)
            } else {
                self = .publicWeb(url)
            }
            return
        }

        var path = text
        if text.hasPrefix("file://") {
            guard let url = URL(string: text), url.isFileURL, url.host == nil || url.host == "",
                  url.path.hasPrefix("/") else { self = .invalid; return }
            path = url.path
        } else if text.contains("://") {
            self = .invalid
            return
        }

        // Terminal file-location suffixes are metadata, never part of the remote filename.
        if let match = path.range(of: #":\d+(?::\d+)?$"#, options: .regularExpression) {
            let prefix = String(path[..<match.lowerBound])
            if !(prefix as NSString).pathExtension.isEmpty || !prefix.contains(":") {
                path = prefix
            }
        }
        guard !path.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) else {
            self = .invalid
            return
        }
        if path == "~" || path.hasPrefix("~/") {
            guard let home, home.hasPrefix("/") else { self = .needsRemoteHome; return }
            path = home + path.dropFirst()
        } else if path.hasPrefix("~") {
            self = .invalid
            return
        }
        if !path.hasPrefix("/") {
            guard let cwd, cwd.hasPrefix("/") else { self = .needsRemoteDirectory; return }
            path = cwd + "/" + path
        }
        var components: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." || part.isEmpty { continue }
            if part == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(part)
        }
        self = .remoteFile(absolutePOSIXPath: "/" + components.joined(separator: "/"))
    }
}
