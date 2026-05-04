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
claude-cask                       # Opus + auto mode
claude-cask --model sonnet        # different model
claude-cask --safe                # default permission prompts (omits --permission-mode auto)
claude-cask --rebuild             # rebuild the image before running
claude-cask -- --resume my-task   # forward args to claude
```

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

## Tests

```bash
bats tests/claude-cask.bats           # unit
bats tests/integration/smoke.bats    # integration (builds image)
shellcheck claude-cask entrypoint.sh  # lint
```
