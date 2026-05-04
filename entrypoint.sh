#!/usr/bin/env bash
set -euo pipefail

# When invoked as root inside the container, do privileged one-time setup:
# chown the bind-mounted host gpg-agent socket so the unprivileged user can
# connect to it, then symlink it into ~claude-cask/.gnupg/. After that, drop
# privileges via gosu and re-exec into the unprivileged section below.
if [[ "$(id -u)" -eq 0 ]]; then
  if [[ -S /run/host-gpg-agent ]]; then
    # Docker Desktop on macOS presents the bind-mounted host socket as
    # root:root mode 660 inside the container. chown it to claude-cask so
    # the unprivileged user can connect, then symlink it to the standard
    # path in claude-cask's home. No long-running bridge process needed.
    install -d -m 700 -o claude-cask -g claude-cask /home/claude-cask/.gnupg
    chown claude-cask:claude-cask /run/host-gpg-agent
    ln -sfn /run/host-gpg-agent /home/claude-cask/.gnupg/S.gpg-agent
  fi

  exec gosu claude-cask "$0" "$@"
fi

# === unprivileged section (runs as claude-cask) ===

KEY_PATH="${CLAUDE_CASK_KEY_PATH:-/tmp/signing-key.asc}"

if [[ -f "$KEY_PATH" && -n "${CLAUDE_CASK_SIGNING_KEY:-}" ]]; then
  mkdir -p "$HOME/.gnupg"
  chmod 700 "$HOME/.gnupg"

  gpg --quiet --batch --import "$KEY_PATH"
  # Do not rm the key file: it is a bind-mount from the host (Device busy)
  # and only contains the public key. Host temp file is cleaned up by the
  # launcher's EXIT trap.

  git config --global user.signingkey "$CLAUDE_CASK_SIGNING_KEY"
  git config --global gpg.program gpg

  if [[ "${CLAUDE_CASK_GPG_SIGN:-false}" == "true" ]]; then
    git config --global commit.gpgsign true
    git config --global tag.gpgsign true
  fi
fi

git config --global user.name  "$GIT_AUTHOR_NAME"
git config --global user.email "$GIT_AUTHOR_EMAIL"

if [[ -n "${CLAUDE_CASK_SKIP_WORKSPACE_CD:-}" ]]; then
  :
else
  # The launcher bind-mounts $PWD at the same in-container path (so per-
  # project Claude Code sessions key off the host path, not a generic
  # /workspace). Fall back to /workspace if the env var isn't set, e.g.
  # when the entrypoint is invoked directly without going through the
  # launcher (the integration smoke test does this).
  cd "${CLAUDE_CASK_WORKDIR:-/workspace}"
fi

exec claude "$@"
