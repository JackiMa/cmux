import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Remote tmux preview target")
struct RemoteTmuxPreviewTargetTests {
    @Test(arguments: [
        ("outputs/fig.png", "/srv/project", "/srv/project/outputs/fig.png"),
        ("./a.png", "/srv/project", "/srv/project/a.png"),
        ("../b.mp4", "/srv/project", "/srv/b.mp4"),
        ("/home/user/a.pdf", "/srv/project", "/home/user/a.pdf"),
        ("file:///home/user/a.png", "/srv/project", "/home/user/a.png"),
        ("~/pics/a.png", "/srv/project", "/home/user/pics/a.png"),
        ("outputs/fig.png:12:3", "/srv/project", "/srv/project/outputs/fig.png"),
    ])
    func remotePaths(raw: String, cwd: String, expected: String) {
        #expect(RemoteTmuxPreviewTarget(raw: raw, cwd: cwd, home: "/home/user")
            == .remoteFile(absolutePOSIXPath: expected))
    }

    @Test func missingContext() {
        #expect(RemoteTmuxPreviewTarget(raw: "/srv/图像 outputs/a.png", cwd: nil, home: nil)
            == .remoteFile(absolutePOSIXPath: "/srv/图像 outputs/a.png"))
        #expect(RemoteTmuxPreviewTarget(raw: "图像 outputs/a.png", cwd: "/srv/project", home: nil)
            == .remoteFile(absolutePOSIXPath: "/srv/project/图像 outputs/a.png"))
        #expect(RemoteTmuxPreviewTarget(raw: "fig.png", cwd: nil, home: nil) == .needsRemoteDirectory)
        #expect(RemoteTmuxPreviewTarget(raw: "~/fig.png", cwd: nil, home: nil) == .needsRemoteHome)
        #expect(RemoteTmuxPreviewTarget(raw: "~other/fig.png", cwd: "/srv", home: "/home/user") == .invalid)
    }

    @Test(arguments: [
        ("http://127.0.0.1:7860/a?x=1#b", "http://127.0.0.1:7860/a?x=1#b"),
        ("http://localhost:3000/", "http://127.0.0.1:3000/"),
        ("http://[::1]:8080/", "http://127.0.0.1:8080/"),
        ("http://0.0.0.0:5000/x", "http://127.0.0.1:5000/x"),
        ("https://localhost/a?x=1#b", "https://127.0.0.1:443/a?x=1#b"),
    ])
    func loopback(raw: String, expected: String) {
        #expect(RemoteTmuxPreviewTarget(raw: raw, cwd: nil, home: nil)
            == .loopbackWeb(URL(string: expected)!))
    }

    @Test func publicAndInvalid() {
        let publicURL = URL(string: "https://example.com/a.png")!
        #expect(RemoteTmuxPreviewTarget(raw: publicURL.absoluteString, cwd: nil, home: nil)
            == .publicWeb(publicURL))
        #expect(RemoteTmuxPreviewTarget(raw: "", cwd: "/srv", home: nil) == .invalid)
        #expect(RemoteTmuxPreviewTarget(raw: "a\nb", cwd: "/srv", home: nil) == .invalid)
        #expect(RemoteTmuxPreviewTarget(raw: "a\u{0}b", cwd: "/srv", home: nil) == .invalid)
        #expect(RemoteTmuxPreviewTarget(raw: "file:///srv/a%0Ab", cwd: "/srv", home: nil) == .invalid)
        #expect(RemoteTmuxPreviewTarget(raw: "http://127.0.0.1:7860", cwd: "/srv", home: nil)
            == .loopbackWeb(URL(string: "http://127.0.0.1:7860")!))
    }
}
