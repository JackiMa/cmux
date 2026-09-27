import Foundation

/// SSH options for one non-interactive channel on an already-running tmux master.
struct RemoteTmuxPreviewSSHOptions {
    let host: RemoteTmuxHost

    var arguments: [String] {
        let original = host.sshControlArguments(controlPersistSeconds: 180, batchMode: true)
        var filtered: [String] = []
        var index = 0
        while index < original.count {
            if original[index] == "-o", index + 1 < original.count,
               (original[index + 1].hasPrefix("ControlMaster=")
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
            // A failed mux connection must never fall back to a fresh TCP login.
            "-o", "ProxyCommand=/usr/bin/false",
        ]
    }
}
