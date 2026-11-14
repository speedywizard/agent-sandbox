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
sbx --net-unix pi       # also allow unix sockets (see Limits)
sbx --project DIR pi    # boundary = DIR instead of the git toplevel
sbx -- bash -lc 'make'  # any command, same boundary
```

Seatbelt profiles are inherited by every child process, so this covers the
agent's shell, its built-in file tools, hooks, MCP servers and subagents in one
boundary — which a shell-only sandbox does not.

## GitHub CLI

`gh` reads `~/.config/gh`, which the profile denies along with the OAuth token
inside it. A read-only token, kept in the login keychain, gives the agent PR and
check output in every repository without a push-capable credential:

```sh
security add-generic-password -a "$USER" -s gh-ro -w 'github_pat_…' -U
```

### Where the token comes from

There is no way to mint a personal access token from the CLI: GitHub exposes no
API for creating them, so `gh` can only store and use what you already have.
(`gh auth token` prints the token `gh` currently uses; `gh auth refresh -s …`
only widens OAuth scopes on the built-in login flow, and `gh auth login
--with-token` accepts a token on stdin — none of them create one.)

Create it in the browser instead:

1. **Settings → Developer settings → Personal access tokens → Fine-grained
   tokens → Generate new token.**
2. Resource owner: yourself, or the organisation if the repositories belong to
   one (an org owner may need to approve it).
3. Repository access: *Only select repositories* for the narrow case, or *All
   repositories* if you want one token for everything.
4. Repository permissions — set these to **Read-only**:
   - **Pull requests** — `gh pr view`, `gh pr checks`, `gh pr diff`
   - **Actions** — `gh run list`, `gh run view --log-failed`
   - **Commit statuses** — the legacy half of a PR's rollup
   - **Contents** — only if you also want `gh pr diff` to fetch file contents
   - **Metadata** is granted automatically and cannot be removed

   There is no *Checks* permission to tick: the Checks API accepts GitHub App
   tokens only, never fine-grained PATs, so check runs cannot be read directly.
   `gh pr checks` uses the server-computed `statusCheckRollup` on the pull
   request instead, which `Pull requests: read` covers — and `gh run view
   --log-failed` (`Actions: read`) gives you the failing job logs either way.
5. Set an expiration, generate, and copy the `github_pat_…` value — it is shown
   once.

If the repositories belong to an organisation, the token may sit **pending
approval** even when you selected the repo: many orgs require it. Until an org
owner approves it under *Org → Settings → Personal access tokens*, every request
against that org's repositories returns **404**, not 403 — the repo looks like it
does not exist, which reads as "wrong account" rather than "not approved yet".
Pending requests are eventually discarded if nobody acts on them.

Check the state from inside the sandbox:

```sh
sbx gh api user/orgs --jq '.[].login'                             # membership
sbx gh api user/memberships/orgs/OWNER --jq .state                # active | pending
sbx gh api repos/OWNER/REPO --jq .full_name                       # 200 means the grant exists
```

Then hand it to `sbx`:

```sh
security add-generic-password -a "$USER" -s gh-ro -w 'github_pat_…' -U
```

To confirm the token is read-only before trusting it with an agent:

```sh
GH_TOKEN=$(security find-generic-password -a "$USER" -s gh-ro -w) gh api user --jq .login
GH_TOKEN=$(security find-generic-password -a "$USER" -s gh-ro -w) gh api rate_limit --jq .resources.graphql.remaining
```

A push attempt with it fails, which is the property that matters:

```sh
GH_TOKEN=… gh api -X PUT /repos/OWNER/REPO/contents/PROBE -f message=x -f content=eA==   # 403/404
```

### Several accounts on the same host

`gh` keeps one token per *host*, so two accounts on `github.com` cannot both be
active — but `sbx` can pick the right one per repository. Store one keychain
item per account, then map owners to items:

```sh
security add-generic-password -a "$USER" -s gh-ro.work     -w 'github_pat_…' -U
security add-generic-password -a "$USER" -s gh-ro.personal -w 'github_pat_…' -U
```

```
# ~/.config/agent-sandbox/gh-accounts
devtactics    gh-ro.work
speedywizard  gh-ro.personal
```

Resolution order:

| step | source |
|---|---|
| 1 | `--gh-profile work` → item `gh-ro.work` |
| 2 | `GH_ITEM` in the environment → that item verbatim |
| 3 | first matching key in `gh-accounts`: absolute path (`/…`), `~/…` path, project directory name, or owner of the `origin` remote |
| 4 | `gh-ro` |

Owner extraction handles `git@github.com:owner/repo.git`,
`https://github.com/owner/repo.git` and `ssh://git@github.com:22/owner/repo.git`.
`SBX_DEBUG=1 sbx …` prints which item was chosen. The file fallback checks
`gh-token.<item>` first, then `gh-token`.

Mapping by owner assumes repositories are namespaced by account or org; if one
account owns repositories across several orgs, list every org that should
resolve to it.

`sbx` reads it with `security find-generic-password` *before* applying the
sandbox, then exports `GH_CONFIG_DIR` (under `~/.local/state`) and `GH_TOKEN`.
A fine-grained token with **Pull requests: read** and **Actions: read** cannot
push. `GH_ITEM` / `GH_ACCOUNT` override the keychain lookup, and `--no-gh` turns
the whole thing off for a session.

A plain file at `~/.config/agent-sandbox/gh-token` is used as a fallback when the
keychain has no such item.

With a token wired in, `sbx` also exports `GIT_ASKPASS` (a tiny helper that
answers with the same token) and `GIT_TERMINAL_PROMPT=0`, so **https** remotes
fetch read-only and `git push` gets a 403. SSH remotes stay broken by design:
`~/.ssh` is unreadable, so neither `~/.ssh/config` aliases nor keys resolve —
switch that repository to an https URL, or pass `--ssh-agent` if you want push.

Selecting *all repositories* for the token also lets the agent read every
repository's code; scope it to selected repositories when that matters more than
convenience. Either way the token is visible to the sandboxed process
environment, so its scope is the ceiling on what a leaked value could do.

## Multi-repo workspaces

`sbx` uses the git toplevel of the working directory, which is what you want in
a single repository. For a workspace that holds several repositories plus notes,
point it at the directory instead:

```sh
cd ~/work/detaso && sbx claude                 # works if detaso is not itself a repo
sbx --project ~/work/detaso claude             # explicit, from anywhere
```

The boundary is then that directory and everything under it — wider than a
single repo, so prefer the narrower run when one project is enough. Account
mapping still works: a `gh-accounts` key may be the workspace path, its
directory name, or a repository owner.

## Verify

```sh
./tests/verify.sh /path/to/some/repo
```

Runs each claim from this file against a scratch repository.

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

Skills are readable regardless of where the session keeps its state:
`~/.agents` for every agent, and `~/.claude` read-only for Claude Code even when
`CLAUDE_CONFIG_DIR` points at a project-specific directory — otherwise custom
config dirs silently lose `~/.claude/skills`. They stay read-only; if something
needs to install into them, add the path to `allow-rw.txt`.

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
- **Unix sockets are a filesystem bypass if you allow them.** Seatbelt's
  `network*` permission covers unix domain sockets, not just TCP, so a profile
  that grants it lets the agent connect to *any* local daemon whose socket it
  knows — the docker socket being the obvious one (`docker run -v ~:/host` ends
  the filesystem boundary instantly). The default profile therefore grants
  `(remote tcp "*:*")`, `(remote udp "*:*")`, local binds and the
  `mDNSResponder` socket only, and `sbx` additionally drops `SSH_AUTH_SOCK`.
  `--net-unix` restores the permissive form. Note that denying a socket *path*
  does not block connecting to it — only the network permission does.
- **`--no-network` is the only way to close egress completely.**
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
