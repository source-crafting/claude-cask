# claude-cask

Run Claude Code inside an ephemeral Docker container with the host working directory mounted, the host `~/.claude` config forwarded, Opus by default, safe-mode permission prompts, and signed commits using exactly one of the host's GPG keys (no private key material exposed to the container).

## Requirements

- macOS (Docker Desktop) or Linux with a working Docker daemon
- `git` configured with at least `user.name` and `user.email` (local repo config overrides global — see *Git identity precedence* below)
- For signed commits: `user.signingkey` set **globally** and `gpg-agent` running. On macOS Docker Desktop, file sharing must include `~/.gnupg`.

## Install

Clone the repo to wherever you keep tools, then symlink the launcher onto your `PATH`:

```bash
git clone git@github.com:source-crafting/claude-cask.git <install-dir>
ln -s <install-dir>/claude-cask /usr/local/bin/claude-cask
```

Replace `<install-dir>` with the path you cloned into (e.g. `~/tools/claude-cask`, `/opt/claude-cask`). The launcher resolves its own location via the symlink, so it works from any clone path.

## Building the image

The image is tagged `claude-cask:latest`. The launcher builds it automatically on first invocation. To build (or rebuild) explicitly:

```bash
# From the cloned repo:
docker build -t claude-cask:latest .

# Or via the launcher:
claude-cask --rebuild
```

The launcher detects when the image is stale and rebuilds automatically:

- The Dockerfile and `entrypoint.sh` are hashed at every launch and compared to the image's `claude-cask.image-hash` label. If they differ (you edited either file), the launcher rebuilds.
- The host UID/GID are compared to the image's `claude-cask.uid`/`claude-cask.gid` labels. If they differ (you've moved the checkout to a different machine), the launcher rebuilds.
- After every successful rebuild, dangling claude-cask images are auto-pruned (label-scoped, so other dangling images on your daemon are left alone).

You only need `--rebuild` to force a rebuild when nothing has changed (e.g., to refresh `@anthropic-ai/claude-code` from npm).

## Usage

```bash
claude-cask                       # Opus + safe mode (per-tool prompts apply)
claude-cask --auto                # opt into auto mode (no per-tool prompts)
claude-cask --model sonnet        # different model
claude-cask --rebuild             # rebuild the image before running
claude-cask --keep-container      # don't pass --rm; container survives for post-mortem
claude-cask -- --resume my-task   # forward args to claude
```

**Safe by default.** Without `--auto`, the in-container Claude prompts before each tool call (the standard Claude Code behavior). Pass `--auto` only when you trust the AI to act in this workspace without per-action confirmation. See *Security* below for what changes when you do.

**Pre-flight summary.** Each launch prints a summary to stderr — workspace path, `~/.claude` mount, signing key, network, mode, and (on macOS) FileVault status — and, when stdin is a tty, asks `Continue? [Y/n]`. The point is to catch "I'm in the wrong directory" mistakes before the container takes hold of the workspace.

**`--keep-container`.** By default `docker run --rm` is used, so when something goes wrong mid-session the container is gone the moment claude exits and there's nothing to `docker logs`. Pass `--keep-container` to drop `--rm` and capture the container id; the launcher prints `docker logs` / `docker inspect` / `docker rm` cleanup hints at exit. You're responsible for `docker rm` when done debugging.

## What gets mounted

| Host path                     | Container path                                                                                                | Notes                                                                                                                                                                                                                                                                                                                                         |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `$PWD`                        | same path inside the container (e.g. `~/projects/foo`)                                                 | Your project. Mounted at the same path so Claude Code's per-project session storage keys off the real path and matches what host `claude` would record. Working directory is also set to it.                                                                                                                                                  |
| `~/.claude`                   | `/home/claude-cask/.claude`                                                                                   | Claude Code config dir: settings, sessions, plugins. Read-write.                                                                                                                                                                                                                                                                              |
| `~/.claude.json` (if present) | `/home/claude-cask/.claude.json`                                                                              | Theme and user-level Claude Code config. Read-write. Mount is skipped silently if the host file is absent.                                                                                                                                                                                                                                    |
| macOS keychain (Darwin only)  | `/home/claude-cask/.claude/.credentials.json` (via the dir mount)                                             | Login token, extracted from `security find-generic-password -s "Claude Code-credentials"` once and written to `~/.claude/.credentials.json` (mode 600) only if that file doesn't already exist. The launcher does not delete it on exit — see SECURITY.md. On Linux, this step is skipped because host Claude already stores the token there. |
| `gpg-agent` extra socket      | `/run/host-gpg-agent`, symlinked into `~claude-cask/.gnupg/S.gpg-agent` after the entrypoint chowns the bind-mount to claude-cask | Signing happens on host; container has no private key access.                                                                                                                                                                                                                                                                                 |
| Single armored public key     | `/tmp/signing-key.asc` (read-only)                                                                            | Only the configured signing key.                                                                                                                                                                                                                                                                                                              |

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

The container runs as a non-root user `claude-cask` whose **UID/GID match the host user** running the launcher. At image-build time the launcher passes `--build-arg USER_UID=$(id -u) USER_GID=$(id -g)`, the Dockerfile creates the user accordingly (deleting whichever existing user/group occupies that UID/GID — typically the base image's `node` user at 1000), and stamps the image with `claude-cask.uid` / `claude-cask.gid` labels. On subsequent launches the labels are checked against the host UID/GID and a rebuild is triggered automatically if they diverge (e.g., you've moved the checkout to a different machine).

The entrypoint runs briefly as root to chown the bind-mounted gpg-agent socket and symlink it into `~claude-cask/.gnupg/` (see *GPG security model* below), then drops privileges to `claude-cask` via `gosu` and re-execs itself. By the time `claude` actually starts, the process is `claude-cask` at the host UID. No long-running root process remains in the container.

This means bind-mounted files are owned by the same UID inside the container as on the host, both on Docker Desktop / macOS (where virtiofs would translate anyway) and on native Linux (where it's the only thing that makes the bind-mounts writable). The launcher refuses to run as host UID 0 (root).

## Git identity precedence

`user.name` and `user.email` follow git's normal precedence inside the launched workspace: a value set in the local repo config (`git config --local user.email work@example.com`) overrides the global value. Use this to commit as different identities in different repos without changing global config.

`user.signingkey` and `commit.gpgsign` are read **only from your global config**. Local overrides for those are intentionally ignored so that the GPG key forwarded into the container is predictable: the launcher exports exactly that key from your host keyring and bind-mounts it read-only. A local-config detour for the signing key would mean a per-repo file could steer which host key gets exported, which is a footgun the launcher chooses not to expose.

If you need a different signing key for a specific project, change your global `user.signingkey` before launching.

## GPG security model

The container never sees:
- Private key material
- Any host pubring data
- Knowledge of any GPG keys other than the one configured signing key

The container can sign commits using the host's `gpg-agent` because:
- Its keyring contains the public key for the one configured signing key
- The host's `gpg-agent` *extra* socket is bind-mounted at `/run/host-gpg-agent`. Docker Desktop on macOS presents that bind-mount as `root:root` mode 660 inside the container, so the entrypoint (running briefly as root) `chown`s it to `claude-cask` and creates a symlink at `~claude-cask/.gnupg/S.gpg-agent`. The unprivileged `claude-cask` user then connects directly to the host's agent through that path. The chown/symlink only changes the container's view; it doesn't touch host-side ownership. No long-running root process or proxy is involved.

If `git config --global user.signingkey` is unset, no GPG mounts are added and signing simply isn't available inside the container.

## Security

claude-cask sandboxes Claude Code so it can work on the project in `$PWD` without reaching the rest of your machine. The full threat model — what the container does and doesn't bound, the nuances of auto-mode, and the per-flag mitigations — is in [SECURITY.md](SECURITY.md). Read it before turning on `--auto`.

Quick summary:
- Default (no flags) is safe mode — Claude prompts for each tool call.
- `--auto` skips per-tool prompts; the AI runs inside the container's bounds without confirmation.
- The container has full outbound network access by default, same as native Claude Code. If you need stricter egress, use Docker's own `--network` controls or run on a host-side firewalled network.

## Tests

```bash
bats tests/claude-cask.bats           # unit
bats tests/integration/smoke.bats    # integration (builds image)
shellcheck claude-cask entrypoint.sh  # lint
```

---

claude-cask is an unofficial wrapper. It launches Claude Code inside a container but does not modify it or distribute it. Claude Code itself is a product of Anthropic and your use of it through this tool is subject to Anthropic's [usage policies](https://www.anthropic.com/legal/aup) and the terms applicable to your Claude account. This project is not affiliated with or endorsed by Anthropic.
