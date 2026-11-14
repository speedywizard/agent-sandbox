# agent-sandbox

Run a coding agent — `pi`, `claude`, or anything else — confined to the project
you're in, using macOS Seatbelt. No VM, no container, no duplicated toolchain:
your editor, dev server and Homebrew binaries stay native, and the agent only
gets the repository.

```
sbx pi                  # sandbox pi to the current project
sbx claude              # same boundary, Claude Code
sbx --no-network pi     # also deny all network egress
sbx --print pi          # dump the generated profile, run nothing
sbx -- bash -lc 'make'  # any command, same boundary
```

Seatbelt profiles are inherited by every child process, so this covers the
agent's shell, its built-in file tools, hooks, MCP servers and subagents in one
boundary — which a shell-only sandbox does not.

## Install

```sh
./install.sh                       # symlinks sbx into ~/.local/bin
```

Then, inside a repository:

```sh
sbx pi
```

Requires macOS. `~/.local/bin` must be on `PATH`; `~/.config/agent-sandbox` is
created on first run.

## What the agent can reach

| | paths |
|---|---|
| read + write | the project (git toplevel, else `$PWD`), `/private/tmp`, `$TMPDIR`, `~/.cache`, `~/.local/state`, `~/Library/Caches`, plus the agent's own state |
| read only | `/usr`, `/bin`, `/sbin`, `/System`, `/System/Volumes`, `/Library`, `/private/etc`, `/dev`, `/opt`, `/nix`, `/tmp`, `/var`, `/etc`, and toolchain caches (`~/.npm`, `~/.cargo`, `~/.rustup`, `~/.pyenv`, `~/.local/share/mise`, …) |
| denied | everything else: `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/Library/Keychains`, `~/Documents`, other repositories, `~/.config` contents |

Agent state added automatically:

- `pi` → `~/.pi` (or `$PI_CODING_AGENT_DIR`), `~/.context-mode`
- `claude` → `~/.claude` (or `$CLAUDE_CONFIG_DIR`), `~/.claude.json`,
  `~/.local/share/claude`, `~/.cache/claude`, `~/Library/Caches/claude-cli-nodejs`

Writes to `.git/hooks` and `.git/config` inside the project are denied, so an
agent can commit but cannot plant a hook that later runs outside the sandbox
when *you* commit, or redirect `core.hooksPath`.

`sbx` also drops `SSH_AUTH_SOCK` before exec. Seatbelt's `network*` permission
covers unix sockets as well as TCP, so an inherited agent socket would otherwise
let a sandboxed agent authenticate to GitHub and push — with nothing readable in
`~/.ssh`. Pass `--ssh-agent` when you do want `git push` to work.

Widen it without editing `sbx`, using `~/.config/agent-sandbox/`:

```
allow-read.txt   # one path per line, read-only
allow-rw.txt     # one path per line, read + write
```

`~` and `$PROJECT` expand; lines starting with `#` are ignored.

## Why the profile looks the way it does

Three Seatbelt behaviours cost real debugging time and are load-bearing:

1. **`(allow file-read* (literal "/"))` is required.** Without it every exec
   aborts with `SIGABRT` and no message, deep inside
   `dyld4::CacheFinder::CacheFinder` — dyld resolves the shared-cache volume by
   opening `/`. It looks nothing like a permission problem.
2. **Each parent directory of an allowed path needs its own `(literal …)`**, or
   `realpath()` fails: node's module loader (`lstat '/Users'`), git and python
   all trip on this.
3. **`(deny default)` also denies `file-ioctl`.** Full-screen apps then misread
   their terminal and *print* the replies to their capability queries, which
   looks like junk such as `^[]11;rgb:…`, `^[[?62;22;52c`,
   `^[P>|ghostty 1.4.0^[\`. `(allow file-ioctl (subpath "/dev"))` fixes it.

Also: unknown operation names fail the whole profile (`sandbox-exec: illegal
sharp expression`), and network filters only accept `*`, `localhost:PORT` or
global names — not `127.0.0.1:PORT`.

## Limits

- **Same UID.** The agent's subprocesses can read whatever the agent can read,
  including its own credentials (`~/.pi`, the keychain with `--keychain`).
  Seatbelt draws the line around the sandbox, not between an agent and itself.
- **Filename metadata leaks.** Ancestor directories must be statable, so the
  agent can see that `~/.ssh` exists and list the names of your home directory;
  it cannot read or write their contents.
- **`/private/tmp` is shared** and writable.
- **`--no-network` is the only way to close egress completely**; with network on,
  unix sockets are reachable, which is why `SSH_AUTH_SOCK` is dropped rather
  than relied on being unreadable.
- **Network is open** unless you pass `--no-network`; the remaining risk with
  secrets unreadable is prompt injection and supply chain, not exfiltration of
  stored credentials.
- `sandbox-exec` is deprecated (man page, 2017) but ships and works on macOS 26.

## Claude Code authentication

Claude Code keeps its OAuth token in the login keychain, which is denied by
default, so a sandboxed session reports `Not logged in`. Either mint a
long-lived token outside the sandbox:

```sh
claude setup-token
export CLAUDE_CODE_OAUTH_TOKEN=…
sbx claude
```

or accept a weaker boundary with `sbx --keychain claude`, which opens
`~/Library/Keychains` read/write — the agent can then reach your other keychain
items (subject to macOS prompts).

## Deliberately not included

Network permission prompts (`allow once / always / deny`) were prototyped and
dropped: Seatbelt sees sockets, not hostnames, so it requires a local CONNECT
proxy plus a decision UI, and anything that doesn't speak proxy protocols fails
closed rather than prompting. A static allowlist + `--no-network` covers the
useful part at a fraction of the complexity.
