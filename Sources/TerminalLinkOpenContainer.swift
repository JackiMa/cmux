import Foundation

/// Host operations needed to give terminal links identical behavior in the
/// workspace grid and the Dock.
@MainActor
protocol TerminalLinkOpenContainer: AnyObject {
    var terminalLinkContainerDebugName: String { get }

    func terminalLinkWorkingDirectory(for sourcePanelId: UUID) -> String?
    func terminalLinkIsRemoteTerminal(_ sourcePanelId: UUID) -> Bool
    func remoteTmuxPreviewContext(for sourcePanelId: UUID) -> RemoteTmuxPreviewContext?

    func cloudTerminalLinkTarget(url: URL, sourcePanelId: UUID) -> CloudTerminalLinkTarget?

    @discardableResult
    func deferTerminalFileLinkOpen(
        sourcePanelId: UUID,
        filePath: String,
        fallback: @escaping @MainActor @Sendable () -> Void
    ) -> Bool

    @discardableResult
    func openTerminalBrowserLink(url: URL, sourcePanelId: UUID, focus: Bool) -> Bool
}

struct CloudTerminalLinkTarget: Sendable, Equatable {
    let url: URL
}

extension TerminalLinkOpenContainer {
    func openTerminalBrowserLink(url: URL, sourcePanelId: UUID) -> Bool {
        openTerminalBrowserLink(url: url, sourcePanelId: sourcePanelId, focus: true)
    }
}

struct RemoteTmuxPreviewContext: Sendable {
    let host: RemoteTmuxHost
    let paneId: Int
}

extension TerminalLinkOpenContainer {
    func remoteTmuxPreviewContext(for sourcePanelId: UUID) -> RemoteTmuxPreviewContext? { nil }
}
