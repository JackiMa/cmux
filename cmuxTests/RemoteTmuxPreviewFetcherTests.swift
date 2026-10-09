import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct RemoteTmuxPreviewFetcherTests {
    @Test(arguments: ["available", "full", "missing", "full-during-download"])
    func fileReadsSurviveUnavailableMuxChannels(master: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("训练 ' curves.png")
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0, 0xff, 0x0a, 0x0d]) + Data(repeating: 0xab, count: 140_000)
        try bytes.write(to: source)
        let host = RemoteTmuxHost(destination: "preview-\(UUID().uuidString).invalid", port: 2207, identityFile: "/test/key")
        let shim = directory.appendingPathComponent("ssh")
        // Model OpenSSH's mux refusal and normal connection fallback, then
        // execute the actual generated remote command in an isolated directory.
        // Real OpenSSH saturation is also covered by the opt-in live check.
        let script = """
        #!/bin/sh
        proxy= normal_master= port= identity= batch=
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -o)
              case "$2" in
                ProxyCommand=*) proxy=${2#ProxyCommand=} ;;
                ControlPath=\(host.controlSocketPath)) normal_master=yes ;;
                BatchMode=yes) batch=yes ;;
              esac
              shift 2 ;;
            -p) port=$2; shift 2 ;;
            -i) identity=$2; shift 2 ;;
            --) shift; break ;;
            *) shift ;;
          esac
        done
        [ "$1" = '\(host.destination)' ] && [ "$port" = 2207 ] && [ "$identity" = /test/key ] && [ "$batch" = yes ] || exit 97
        shift
        mode=\(master)
        if [ "$mode" = full-during-download ]; then
          case "$1" in *'cat --'*) mode=full ;; *) mode=available ;; esac
        fi
        if [ "$mode" = available ]; then
          # An authenticated master must still work without fresh-login access.
          [ "$normal_master" = yes ] || { echo 'Permission denied (publickey).' >&2; exit 255; }
        elif [ "$proxy" = /usr/bin/false ]; then
          echo 'mux_client_request_session: session request failed: Session open refused by peer' >&2
          echo 'Connection closed by UNKNOWN port 65535' >&2
          exit 255
        fi
        exec /bin/sh -c "$1"
        """
        try script.write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
        let fetcher = RemoteTmuxPreviewFetcher(sshExecutablePath: shim.path)
        for (path, cwd) in [(source.path, "/absent-directory"), (source.lastPathComponent, directory.path)] {
            let downloaded = try await fetcher.fetch(path: path, cwd: cwd, host: host)
            defer { try? FileManager.default.removeItem(at: downloaded) }
            #expect(try Data(contentsOf: downloaded) == bytes)
        }
        #expect(try await fetcher.remoteHome(host: host) == FileManager.default.homeDirectoryForCurrentUser.path)
    }
}
