import Foundation

/// Non-interactive SSH options for file reads and browser forwarding.
struct RemoteTmuxPreviewSSHOptions {
    let host: RemoteTmuxHost

    /// Browser forwarding stays bound to the authenticated terminal master.
    var arguments: [String] {
        baseArguments + ["-o", "ProxyCommand=/usr/bin/false"]
    }

    /// Reuse the master when possible. OpenSSH can authenticate a separate
    /// connection when tmux control clients exhaust its session channels.
    /// Preserve the host's identity, proxy and host-key policies; never prompt.
    var fileReadArguments: [String] {
        baseArguments + ["-T", "-n", "-o", "ClearAllForwardings=yes"]
    }

    private var baseArguments: [String] {
        let original = host.sshControlArguments(controlPersistSeconds: 180, batchMode: true)
        var filtered: [String] = []
        var index = 0
        while index < original.count {
            if original[index] == "-o", index + 1 < original.count,
               (original[index + 1].hasPrefix("ControlMaster=")
                || original[index + 1].hasPrefix("ControlPath=")
                || original[index + 1].hasPrefix("ControlPersist=")) {
                index += 2
                continue
            }
            filtered.append(original[index])
            index += 1
        }
        return filtered + [
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(host.controlSocketPath)",
            "-o", "BatchMode=yes",
        ]
    }
}
