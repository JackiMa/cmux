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

The separation between tmux windows and a local browser is also proposed in
[upstream PR #9861](https://github.com/manaflow-ai/cmux/pull/9861). This fork's
preview pane additionally hosts downloaded files. Keep fixes scoped to this
fork while that upstream work is open.
