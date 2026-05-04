# claude-cask

Run Claude Code inside an ephemeral Docker container with the host working directory mounted, the host `~/.claude` config forwarded, sensible defaults (Opus + auto mode), and signed commits using exactly one of the host's GPG keys (no private key material exposed to the container).

## Requirements

- macOS with Docker Desktop (Linux likely works but isn't a launch target)
- `git` configured globally with at least `user.name` and `user.email`
- For signed commits: `user.signingkey` set and `gpg-agent` running (Docker Desktop must have file sharing enabled for `~/.gnupg`)

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
| `~/.claude` | `/root/.claude` | Claude Code config, sessions, plugins. Read-write. |
| `gpg-agent` extra socket | `/root/.gnupg/S.gpg-agent` | Signing happens on host; container has no private key access. |
| Single armored public key | `/tmp/signing-key.asc` (read-only) | Only the configured signing key. |

## GPG security model

The container never sees:
- Private key material
- Any host pubring data
- Knowledge of any GPG keys other than the one configured signing key

The container can sign commits using the host's `gpg-agent` because:
- Its keyring contains the public key for that one key
- The agent socket is forwarded so the agent (still on the host, holding the secrets) is asked to sign

If `git config --global user.signingkey` is unset, no GPG mounts are added and signing simply isn't available inside the container.

## Tests

```bash
bats tests/claude-cask.bats           # unit
bats tests/integration/smoke.bats    # integration (builds image)
shellcheck claude-cask entrypoint.sh  # lint
```
