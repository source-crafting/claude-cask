REA# claude-cask

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

| Host path                     | Container path                                                                                                | Notes                                                                                                                                                                                                                                                                                                                                                 |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `$PWD`                        | same path inside the container (e.g. `~/projects/foo`)                                                 | Your project. Mounted at the same path so Claude Code's per-project session storage keys off the real path and matches what host `claude` would record. Working directory is also set to it.                                                                                                                                                          |
| `~/.claude`                   | `/home/claude-cask/.claude`                                                                                   | Claude Code config dir: settings, sessions, plugins. Read-write.                                                                                                                                                                                                                                                                                      |
| `~/.claude.json` (if present) | `/home/claude-cask/.claude.json`                                                                              | Theme and user-level Claude Code config. Read-write. Mount is skipped silently if the host file is absent.                                                                                                                                                                                                                                            |
| macOS keychain (Darwin only)  | `/home/claude-cask/.claude/.credentials.json` (via the dir mount)                                             | Login token, extracted from `security find-generic-password -s "Claude Code-credentials"` once and written to `~/.claude/.credentials.json` (mode 600) only if that file doesn't already exist. The launcher does not delete it on exit — see SECURITY.md. On Linux, this step is skipped because host Claude already stores the token there. |
| `gpg-agent` extra socket      | `/run/host-gpg-agent` (a `socat` bridge inside the container exposes it as `~claude-cask/.gnupg/S.gpg-agent`) | Signing happens on host; container has no private key access.                                                                                                                                                                                                                                                                                         |
| Single armored public key     | `/tmp/signing-key.asc` (read-only)                                                                            | Only the configured signing key.                                                                                                                                                                                                                                                                                                                      |

## Login state

**Linux host.** Host Claude Code already keeps its OAuth token at `~/.claude/.credentials.json`. The existing `~/.claude → /home/claude-cask/.claude` directory mount carries the file straight into the container, so the in-container Claude is logged in with no extra work. Token refreshes inside the container write back to the host file via the RW mount, so they persist naturally — same as the host `claude` would do.

If you've never run host `claude` (no `~/.claude/.credentials.json` exists yet), run `/login` inside the container the first time. It writes to the host file via the mount, and subsequent runs are logged in.

**macOS host.** Claude Code stores its OAuth token in the Keychain rather than in any file. The first time you run claude-cask, the launcher extracts the token from the keychain and writes it to `~/.claude/.credentials.json` (mode 600), where the in-container Claude reads it via the existing directory mount. On subsequent runs the file is already there and the launcher leaves it alone.

(A separate file bind-mount inside `/home/claude-cask/.claude/` is not used: Docker Desktop's virtiofs can't stack a file mount inside a directory bind-mount.)

The launcher **does not** delete the credentials file on exit — doing so would break any concurrent claude session reading the same file. The file persists on disk indefinitely. With FileVault on and an encrypted Time Machine destination, this is roughly equivalent in security to the keychain itself; see [SECURITY.md](SECURITY.md) for the threat model and mitigation guidance.

If you want to force a refresh from the keychain (e.g., after re-logging-in on the host), `rm ~/.claude/.credentials.json` and the next claude-cask launch will re-stage from the keychain.

If you also run host `claude` (e.g., for `/login`) occasionally, the keychain stays fresh. If you only ever use claude-cask, eventually the in-container refresh token rotates and the on-disk file gets newer than the keychain — that's fine, the file is what gets read on subsequent launches.

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

## Security

claude-cask sandboxes Claude Code so it can work on the project in `$PWD` without reaching the rest of your machine. The full threat model — what the container does and doesn't bound, the nuances of auto-mode, and the per-flag mitigations — is in [SECURITY.md](SECURITY.md). Read it before turning on `--auto`.

Quick summary:
- Default (no flags) is safe mode — Claude prompts for each tool call.
- `--auto` skips per-tool prompts; the AI runs inside the container's bounds without confirmation.
- `--anthropic-only` restricts outbound network to `api.anthropic.com` (kernel-enforced via iptables + a tinyproxy allowlist). Pair this with `--auto` for the cleanest mitigation against accidental exfiltration.

## Tests

```bash
bats tests/claude-cask.bats           # unit
bats tests/integration/smoke.bats    # integration (builds image)
shellcheck claude-cask entrypoint.sh  # lint
```
