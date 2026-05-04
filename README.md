# claude-cask

Run Claude Code inside an ephemeral Docker container with the host working directory mounted, the host `~/.claude` config forwarded, sensible defaults (Opus + auto mode), and signed commits using exactly one of the host's GPG keys (no private key material exposed to the container).

## Requirements

- macOS (Docker Desktop) or Linux with a working Docker daemon
- `git` configured globally with at least `user.name` and `user.email`
- For signed commits: `user.signingkey` set and `gpg-agent` running. On macOS Docker Desktop, file sharing must include `~/.gnupg`.

## Install

```bash
git clone <this-repo> ~/claude-cask
ln -s ~/claude-cask/claude-cask /usr/local/bin/claude-cask
```

## Building the image

The image is tagged `claude-cask:latest`. The launcher builds it automatically on first invocation. To build (or rebuild) explicitly:

```bash
# From the cloned repo:
docker build -t claude-cask:latest .

# Or via the launcher:
claude-cask --rebuild
```

After editing `Dockerfile` or `entrypoint.sh`, you must rebuild — the launcher does **not** detect changes on its own (it only auto-builds when the image is missing).

## Usage

```bash
claude-cask                       # Opus + safe mode (per-tool prompts apply)
claude-cask --auto                # opt into auto mode (no per-tool prompts)
claude-cask --model sonnet        # different model
claude-cask --anthropic-only      # restrict egress: only api.anthropic.com is reachable
claude-cask --rebuild             # rebuild the image before running
claude-cask -- --resume my-task   # forward args to claude
```

**Safe by default.** Without `--auto`, the in-container Claude prompts before each tool call (the standard Claude Code behavior). Pass `--auto` only when you trust the AI to act in this workspace without per-action confirmation. See *Security* below for what changes when you do.

**Pre-flight summary.** Each launch prints a summary of mounts, signing key, network, and mode, and (when stdin is a tty) asks for confirmation. The point is to catch "I'm in the wrong directory" mistakes before the container takes hold of the workspace.

**Restricted egress (`--anthropic-only`).** Only `api.anthropic.com` is reachable from inside the container. Everything else — `example.com`, `pastebin.com`, raw TCP to arbitrary IPs, the works — is dropped at the kernel level by iptables, so even tools that ignore `HTTPS_PROXY` (or that try raw sockets) can't get out.

Implementation: a small in-container HTTPS proxy ([tinyproxy](https://tinyproxy.github.io/)) is configured with a one-line allowlist (`^api\.anthropic\.com$`). iptables drops all OUTPUT except (a) loopback, (b) DNS, (c) established connections, and (d) traffic from the proxy's UID. The unprivileged `claude-cask` user has no other path out — its only way to reach the network is `HTTPS_PROXY=http://127.0.0.1:8888`, which only forwards to Anthropic.

This requires `--cap-add=NET_ADMIN` (granted automatically by the launcher when this flag is set; not granted otherwise).

Claude Code itself works normally — its API calls go through the proxy. Anything else the AI tries to reach is blocked.

## What gets mounted

| Host path | Container path | Notes |
|-----------|----------------|-------|
| `$PWD` | `/workspace` | Your project. Working directory inside the container. |
| `~/.claude` | `/home/claude-cask/.claude` | Claude Code config dir: settings, sessions, plugins. Read-write. |
| `~/.claude.json` (if present) | `/home/claude-cask/.claude.json` | Theme and user-level Claude Code config. Read-write. Mount is skipped silently if the host file is absent. |
| macOS keychain (Darwin only) | `/home/claude-cask/.claude/.credentials.json` (via the dir mount) | Login token, extracted from `security find-generic-password -s "Claude Code-credentials"`. Staged on the host as `~/.claude/.credentials.json` (mode 600) just before launch and removed on exit. On Linux, this step is skipped — host Claude already stores the token in `~/.claude/.credentials.json`, which is carried in by the directory mount. |
| `gpg-agent` extra socket | `/run/host-gpg-agent` (a `socat` bridge inside the container exposes it as `~claude-cask/.gnupg/S.gpg-agent`) | Signing happens on host; container has no private key access. |
| Single armored public key | `/tmp/signing-key.asc` (read-only) | Only the configured signing key. |

## Login state

**Linux host.** Host Claude Code already keeps its OAuth token at `~/.claude/.credentials.json`. The existing `~/.claude → /home/claude-cask/.claude` directory mount carries the file straight into the container, so the in-container Claude is logged in with no extra work. Token refreshes inside the container write back to the host file via the RW mount, so they persist naturally — same as the host `claude` would do.

If you've never run host `claude` (no `~/.claude/.credentials.json` exists yet), run `/login` inside the container the first time. It writes to the host file via the mount, and subsequent runs are logged in.

**macOS host.** Claude Code stores its OAuth token in the Keychain rather than in any file. claude-cask extracts it via `security` at launch time, writes it to `~/.claude/.credentials.json` (mode 600) so it's visible in the container via the existing directory mount, and removes the file again on exit.

(A separate file bind-mount inside `/home/claude-cask/.claude/` is not used: Docker Desktop's virtiofs can't stack a file mount inside a directory bind-mount and rejects it with "mountpoint is outside of rootfs".)

If `~/.claude/.credentials.json` already exists on the host, claude-cask leaves it alone and uses it as-is. (A zero-byte file is treated as a stale leftover and overwritten.)

If you also run host `claude` (e.g., for `/login`) occasionally, the keychain stays fresh and claude-cask keeps working. If you only ever use claude-cask, the keychain isn't refreshed — eventually the token rotates and you'll need to run host `claude` once to update the keychain.

## Terminal compatibility

Claude Code adapts its keybindings (notably Shift/Ctrl+Enter for inserting a newline) based on the terminal program running it. claude-cask forwards `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, and `COLORTERM` from the host into the container so the in-container Claude sees the same terminal as on the host (iTerm, Ghostty, VS Code, etc.) and uses matching key sequences.

If a variable is unset on the host, it's not forwarded. `TERM` itself is set automatically by `docker run -t`.

## Container user

The container runs as a non-root user `claude-cask` (UID 1000). The base `node:24-slim` image's default `node` user is removed so `claude-cask` can claim UID 1000.

The entrypoint runs briefly as root to set up the gpg-agent socket bridge (see *GPG security model* below), then drops privileges to `claude-cask` via `gosu` and re-execs itself. By the time `claude` actually starts, the process is `claude-cask`.

On Docker Desktop (macOS), virtiofs handles UID translation transparently — the container user can read/write host bind-mounts regardless of host UID. On native Linux, host file ownership is preserved literally, so for write access to the bind-mounts your host user's UID should also be 1000 (the typical first-user UID).

## GPG security model

The container never sees:
- Private key material
- Any host pubring data
- Knowledge of any GPG keys other than the one configured signing key

The container can sign commits using the host's `gpg-agent` because:
- Its keyring contains the public key for the one configured signing key
- The host's `gpg-agent` *extra* socket is bind-mounted at `/run/host-gpg-agent`, and the entrypoint runs a `socat` bridge (as root, before dropping privileges) that exposes it as a `claude-cask`-owned socket at `~claude-cask/.gnupg/S.gpg-agent` mode 600. When the in-container `gpg` (or `git commit -S`) connects to that socket, `socat` proxies the connection to the host's agent, which performs the actual signing. Private keys stay on the host.

The bridge is needed because Docker Desktop on macOS presents bind-mounted unix sockets as `root:root` mode 660 inside the container — the unprivileged `claude-cask` user can't connect to them directly. The bridge adds no capability beyond what the agent's `extra-socket` already grants; it's a transparent byte-for-byte proxy.

If `git config --global user.signingkey` is unset, no GPG mounts are added and signing simply isn't available inside the container.

## Security model — what claude-cask does and doesn't do

**The sandbox boundary is the container.** Anything Claude does (or anything Claude is convinced to do via prompt injection) is bounded by what's mounted in: `$PWD`, `~/.claude`, `~/.claude.json`, the gpg-agent socket, and the single signing public key. The container is `--rm` and ephemeral.

**In safe mode (default), every tool call asks for permission.** This is the standard Claude Code behavior. Use this when you're not sure what the AI will do, or when the workspace contains code/data you wouldn't want it to modify without seeing each action first.

**In auto mode (`--auto`), Claude runs tool calls without confirmation.** That's the deliberate trade-off: convenience for the AI to keep working, at the cost of human-in-the-loop on each action. The blast radius is still bounded by the container's mounts and network — but inside that box, the AI can do anything it can do natively. Specifically, in auto mode:
- The AI's `Read` tool can read `~/.claude/.credentials.json` (the OAuth token). With egress not restricted, that means the token could be exfiltrated. *(This is no different from running host `claude` with auto-mode — same file, same reachability — but worth being explicit.)*
- The AI's `Bash` and `Edit` tools can modify any file under `$PWD` and `~/.claude`. Writes to `~/.claude/plugins/` or hooks would persist across container exits and affect the host's own Claude Code.
- The forwarded gpg-agent will sign any data the AI asks it to sign. Signed commits made during the session look identical to ones the user typed by hand.

**Mitigations available in claude-cask:**
- `--anthropic-only` restricts the container's egress to `api.anthropic.com` only. Claude still works; everything else (any other host, any raw socket) is dropped by iptables. The cleanest mitigation against exfiltration of secrets reachable inside the container.
- Don't pass `--auto` (default safe mode) — keeps per-tool prompts.
- The pre-flight summary that prints before each launch is your last chance to notice "wrong directory" or "forgot --anthropic-only."

**What is *not* mitigated:**
- Without `--anthropic-only`, the AI in auto mode can still read and exfiltrate any file inside the container's mounts.
- Even with `--anthropic-only`, the AI can sign commits as the user during the session and persist data into `~/.claude` (which the host's own Claude will see).
- Token rotations made inside the container do not propagate back to the macOS keychain — see *Login state*.

## Tests

```bash
bats tests/claude-cask.bats           # unit
bats tests/integration/smoke.bats    # integration (builds image)
shellcheck claude-cask entrypoint.sh  # lint
```
