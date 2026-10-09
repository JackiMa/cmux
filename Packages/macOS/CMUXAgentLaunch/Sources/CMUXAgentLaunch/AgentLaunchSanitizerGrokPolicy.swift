import Foundation

extension AgentLaunchSanitizer {
    static let grokPolicy = Policy(
        valueOptions: [
            "--agent",
            "--agents",
            "--allow",
            "--cwd",
            "--deny",
            "--disallowed-tools",
            "--effort",
            "--max-turns",
            "--model",
            "-m",
            "--permission-mode",
            "--reasoning-effort",
            "--resume",
            "-r",
            "--rules",
            "--sandbox",
            "--session-id",
            "-s",
            "--system-prompt-override",
            "--tools",
            "--worktree",
            "-w"
        ],
        optionalValueOptions: [
            "--resume",
            "-r",
            // Older captures dropped the UUID but retained this selector.
            "--session-id",
            "-s",
            "--worktree",
            "-w"
        ],
        nonRestorableCommands: [
            "agent",
            "help",
            "import",
            "inspect",
            "leader",
            "login",
            "mcp",
            "memory",
            "models",
            "sessions",
            "setup",
            "share",
            "ssh",
            "trace",
            "update",
            "version",
            "v",
            "worktree"
        ],
        droppedOptions: [
            "--continue",
            "-c",
            "--fork-session",
            "--restore-code",
            "--resume",
            "-r",
            "--session-id",
            "-s",
            "--worktree",
            "-w"
        ],
        droppedOptionPrefixes: [
            "--resume=",
            "-r=",
            "--session-id=",
            "-s=",
            "--worktree=",
            "-w="
        ],
        rejectOptions: [
            "--best-of-n",
            "--output-format",
            "--prompt-file",
            "--prompt-json",
            "--single",
            "-p"
        ]
    )
}
