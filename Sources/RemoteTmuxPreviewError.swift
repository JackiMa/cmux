import Foundation

/// Short, localized failures for remote link previews.
enum RemoteTmuxPreviewError: LocalizedError {
    case connectionUnavailable
    case forwardUnavailable
    case remoteFileUnavailable
    case fileTooLarge
    case sourcePaneClosed
    case browserUnavailable
    case filePreviewUnavailable
    case remoteDirectoryUnavailable
    case remoteHomeUnavailable
    case invalidLink
    case remoteDetail(String)

    var errorDescription: String? {
        switch self {
        case .connectionUnavailable:
            return String(localized: "remoteTmux.preview.connectionUnavailable", defaultValue: "SSH connection unavailable")
        case .forwardUnavailable:
            return String(localized: "remoteTmux.preview.forwardUnavailable", defaultValue: "Could not start the local web forward")
        case .remoteFileUnavailable:
            return String(localized: "remoteTmux.preview.remoteFileUnavailable", defaultValue: "Remote file is missing or is not a regular file")
        case .fileTooLarge:
            return String(localized: "remoteTmux.preview.fileTooLarge", defaultValue: "Remote file exceeds 256 MB")
        case .sourcePaneClosed:
            return String(localized: "remoteTmux.preview.sourcePaneClosed", defaultValue: "Source terminal pane closed")
        case .browserUnavailable:
            return String(localized: "remoteTmux.preview.browserUnavailable", defaultValue: "cmux browser unavailable")
        case .filePreviewUnavailable:
            return String(localized: "remoteTmux.preview.filePreviewUnavailable", defaultValue: "File preview unavailable")
        case .remoteDirectoryUnavailable:
            return String(localized: "remoteTmux.preview.remoteDirectoryUnavailable", defaultValue: "Remote working directory unavailable")
        case .remoteHomeUnavailable:
            return String(localized: "remoteTmux.preview.remoteHomeUnavailable", defaultValue: "Remote home directory unavailable")
        case .invalidLink:
            return String(localized: "remoteTmux.preview.invalidLink", defaultValue: "Invalid remote link")
        case .remoteDetail(let detail):
            return detail
        }
    }
}
