# Remote tmux link previews in this fork

This checkout adds ptmux session discovery and remote link previews to the
0.64.25 based `gema/latest-ptmux` branch. ptmux manages the remote tmux sessions;
the macOS app renders them through tmux control mode over SSH.

## Project map

| Responsibility | Files |
| --- | --- |
| Discover and restore ptmux sessions | `Sources/RemoteTmuxSSHTransport.swift` |
| Own SSH connections and preview services | `Sources/RemoteTmuxController.swift` |
| Mirror remote windows and panes | `Sources/RemoteTmuxSessionMirror*.swift`, `Sources/RemoteTmuxWindowMirror*.swift` |
| Classify a clicked URL or file path | `Sources/RemoteTmuxPreviewTarget.swift` |
| Resolve the clicked terminal's host and directory | `Sources/Workspace+TerminalLinkOpening.swift` |
| Fetch a remote file through SSH | `Sources/RemoteTmuxPreviewFetcher.swift` |
| Forward remote localhost HTTP traffic | `Sources/RemoteTmuxLoopbackForwarder.swift` |
| Route a click into a browser or file preview | `Sources/TerminalLinkOpenCoordinator.swift` |
| Create and place local preview panels | `Sources/Workspace.swift` |

Absolute file paths are read directly on the remote host, without changing to
the terminal directory. They also work when that directory is unknown or has
been removed. Relative paths query the clicked tmux pane's current directory at
click time and resolve against it, including immediately after a remote `cd`.
The local terminal directory and cached sidebar directory do not affect this
lookup. A directory used inside an agent's tool
call can differ from the tmux shell directory, so agent output should use an
absolute remote path when linking to an artifact outside the shell directory.
If the resulting remote path does not exist, report that path; do not search
other directories for a matching filename.

File reads first reuse the terminal's SSH master. When its session channels are
full or its socket is gone, OpenSSH can use a separate non-interactive connection
with the same destination, port, identity and configured proxy. Host-key checks
and authentication policy still apply; no password prompt is opened. This also
applies to file-size and home-directory queries. Configured port forwards are
cleared on file-read connections so a download cannot collide with an existing
listener. No SSH server configuration change is needed.

`Session open refused by peer` can occur after many tmux sessions are restored:
each control client occupies an SSH session channel. Web forwarding uses a
different channel type and can still work. See OpenSSH's
[MaxSessions documentation](https://man.openbsd.org/sshd_config#MaxSessions).

For example, if the shell is in `/srv/project` but the image is
`/srv/project/artifacts/run/visuals/frames.png`, use that absolute path or
`artifacts/run/visuals/frames.png`. The link `visuals/frames.png` alone refers
to `/srv/project/visuals/frames.png`.

Remote `http://127.0.0.1:PORT/` and `http://localhost:PORT/` URLs refer to the
SSH host. The preview service allocates a free local port and carries traffic
through the existing SSH master. The resulting local port can differ from
the remote port. A disconnected SSH master must be reconnected first.

## Initialize and build

Read `AGENTS.md` and the relevant `skills/` instructions before editing.
For a new standalone checkout, run `./scripts/setup.sh`. An existing checkout
can reuse its initialized submodules, git hooks, GhosttyKit, and tagged
DerivedData. Avoid a cold Ghostty build when the verified prebuilt framework
is already available.

Standalone builds use `./scripts/reload.sh --tag ptmux-preview`. Team fleet
builds use `cmux-ci` as documented in `AGENTS.md`. Use
`CMUX_TAG=ptmux-preview scripts/cmux-debug-cli.sh ...` for the matching app's
CLI. Do not use the unscoped `/tmp/cmux-cli` helper.

## Focused verification

`RemoteTmuxPreviewTargetTests` covers path and localhost URL classification.
`RemoteTmuxPreviewFetcherTests` executes file reads with available, saturated,
missing, and newly saturated mux channels, including binary data and quoted paths.
`RemoteTmuxPreviewRoutingTests` exercises real workspace browser/file creation,
pane placement, focus preservation, and the absence of unintended tmux splits.
Run these through the `cmux-unit` scheme with a tagged DerivedData path and
bundle identifier; `reload.sh` alone does not execute them.

For a live check, click an absolute remote PNG path and a remote localhost URL.
Both should open beside the mirrored terminals. Open a second preview, focus
it, and create a remote tmux window: the new window must remain in the tmux
tab strip. Closing the preview must leave the remote tmux panes intact.

If a file is unavailable, inspect the resolved absolute path in the error.
Check that exact path on the SSH host before changing browser or SSH settings.
For a web URL, first check the service on the host with
`curl -I --max-time 5 http://127.0.0.1:PORT/`.

An SSH session that can run tmux and read files can still forbid TCP forwarding.
In particular, `no-port-forwarding` on the selected `authorized_keys` entry
rejects `ssh -W` channels. The local listener can start successfully while every
HTTP request receives an empty response. Check the actual forwarded response,
not only whether a local port is listening. Changes to SSH authorization require
the owner's approval and a new SSH connection to take effect.

For a single approved preview port, `permitopen="127.0.0.1:6013"` limits
the key's TCP destinations. If replacing `no-port-forwarding`, also constrain
`permitlisten` so reverse listeners do not become unrestricted. Preserve the
forced command and the key's other restrictions, and back up the file first.
Verify both the allowed port and a denied port with a fresh authentication;
an already connected ControlMaster retains its previous authorization.

## Remote workspace reopen

Remote tmux workspaces now participate in the normal per-window session snapshot.
The saved target contains the SSH destination, port, identity-file path, and tmux
session name. Restore reserves process-free terminal displays in the same workspace,
then reconnects after the restored workspace graph is installed. Existing tmux panes
and their agent processes remain on the host; restore never replays their saved
commands locally or creates a replacement remote session.

The local browser/file preview pane is retained alongside the tmux window strip.
For localhost links opened from a remote terminal, the snapshot saves the original
remote URL. A fresh SSH connection allocates a new local forwarding port before
loading that browser. It does not reuse the previous connection's transient port.
A host that cannot be reached retains its attachment target; an explicit `ssh-tmux`
retry reuses that workspace. Closing a workspace cancels an in-flight restore.

`RemoteTmuxSessionSnapshotTests` covers snapshot round trips, remote-only windows,
process-free placeholders, exact workspace reuse, preview placement, and invalid
attachment targets. A live reopen check should compare tmux pane/process identities
before and after closing the app, then verify the browser uses a working new forward.

`RemoteTmuxPreviewIntegrationTests` is an opt-in SSH check of the terminal-link
coordinator against a real image and web service. It creates one uniquely named
temporary tmux session, verifies the downloaded SHA-256 and forwarded HTTP response,
and removes its session. Normal test runs skip it. Supply a private JSON fixture
with `destination`, optional `port` and `identityFile`, `imagePath`, `imageSHA256`,
`webURL`, and `pageMarker`; it references an existing SSH identity without copying
key material. Pass its path through `TEST_RUNNER_CMUX_LIVE_PTMUX_FIXTURE` when
running the targeted native suite with the tag's DerivedData and test bundle ID.
The test exercises the same coordinator invoked by terminal link clicks; it does
not synthesize a physical Cmd-click gesture.

To reproduce channel exhaustion against an already saturated terminal master,
pass a fixture for that exact connection identity through
`TEST_RUNNER_CMUX_LIVE_PTMUX_BUSY_FIXTURE`. The additional live test first requires
the real mux refusal, then verifies absolute and relative binary downloads by
SHA-256. It only reads from that master and never closes or replaces it.

## Agent restore diagnosis

Each build tag owns a separate session snapshot in
`~/Library/Application Support/cmux/`. The `-previous.json` file holds the
startup backup. Back up both files before another restart when investigating
a missed restore. Do not copy one tag's snapshot over a running app's file.

`terminal.autoResumeAgentSessions` defaults to `true` in this fork. A saved
session ID alone does not trigger automatic resume: the terminal must have
been confirmed to contain a running agent, and its binding must permit the
launch. A saved shell keeps its last agent available for manual continuation.
An agent still running in another cmux instance also prevents a duplicate
launch. Remote tmux sessions are reattached rather than relaunched locally.

The 2026-09-27 investigation found both `fix-ptmux` and `ptmux-preview` running.
The old instance still contained two Codex processes and a Grok process. The
new instance's startup backup included shell records and a Codex hook binding
with `autoResume=false`; its deferred restore was cancelled. Those are
different cases from a missing session ID. Preserve the old instance until its
active work can be stopped intentionally; migrating tags is not a live PTY
transfer. `cmux restore <kind> <id>` runs in the invoking terminal and checks
that terminal's saved identity. It must not be sent to an unrelated agent pane.

The recovery reconciliation repairs that contradictory automatic binding when
the versioned observation confirms the same agent on the same surface, the
saved running state is true, and the binding still has automatic approval.
Both workspace and Dock restores apply it before deferred admission. Fresh
snapshot evidence also repairs the persisted copy. Manual and prompted
approval, unknown/exited states, identity conflicts, other surfaces, and
persistent-session attachment do not gain automatic launch permission. The
existing live-owner check still prevents duplicate agent processes. Records
already saved as shells keep their exact ID for explicit manual continuation.

Resume arguments also preserve the existing conversation's identity and options.
Grok's `--session-id` / `-s` and `--fork-session` selectors are removed before
adding the saved resume ID; older captures with a dangling `--session-id` are
handled as well. Claude's explicit empty variadic values, such as `--tools ''`,
remain empty arguments through capture and resume. Dropping that argument leaves
an invalid command and loses the user's tool restriction. `AgentResumeArgvTests`
checks both paths through the launch sanitizer and resume command builder.

Startup can briefly lack a complete process census while restored terminals and
hooks start together. Restore admission now distinguishes that transient failure
from an unreadable durable hook store. The CLI's existing bounded retry waits for
a complete census before launching; corrupt records and live owners still block
automatic launch.

Codex prompt-depth records belong to the process that produced them. A stopped
or interrupted process can leave depth behind even after its turn ledger settled.
A verified newer process may refresh that session's hook identity and resume
binding; same-process or unverifiable startup callbacks cannot clear an active
turn. This lets a resumed, idle Codex session remain restorable on the next app
reopen without requiring another prompt. `CLICodexHookTimeoutRegressionTests`
exercises the packaged CLI against completed, idle-with-depth, and interrupted
records, while retaining the stale same-process callback checks.

The embedded CLI also needs its SwiftPM localization bundle beside the binary.
The build resource phase exposes the app's `CmuxFoundation_CmuxFoundation.bundle`
under `Resources/bin/`. Without that link, CLI help and config validation crash
even though socket commands such as `ping` work. Verify the packaged CLI, with
no `PACKAGE_RESOURCE_BUNDLE_PATH` override, rather than the top-level build
product. `tests/test_build_app_bundled_resources.sh` exercises cold and cached
resource installation and repair of a missing CLI resource link.

The separation between tmux windows and a local browser is also proposed in
[upstream PR #9861](https://github.com/manaflow-ai/cmux/pull/9861). This fork's
preview pane additionally hosts downloaded files. Keep fixes scoped to this
fork while that upstream work is open.
