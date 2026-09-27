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

The terminal's own tmux pane supplies the remote working directory. Relative
paths resolve against that directory. A directory used inside an agent's tool
call can differ from the tmux shell directory, so agent output should use an
absolute remote path when linking to an artifact outside the shell directory.

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
