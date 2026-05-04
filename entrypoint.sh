#!/usr/bin/env bash
set -euo pipefail

# When invoked as root inside the container, do privileged one-time setup:
#   * If the host's gpg-agent socket has been bind-mounted at
#     /run/host-gpg-agent, stand up a socat bridge that exposes it as a
#     claude-cask-owned socket at the standard ~claude-cask/.gnupg/S.gpg-agent
#     path. Docker Desktop's virtiofs presents the bind-mounted socket as
#     root:root mode 660, so the unprivileged claude-cask user cannot connect
#     to it directly — the bridge is the workaround.
# Then re-exec self under claude-cask via gosu and continue with the
# unprivileged section.
if [[ "$(id -u)" -eq 0 ]]; then
  if [[ -S /run/host-gpg-agent ]]; then
    install -d -m 700 -o claude-cask -g claude-cask /home/claude-cask/.gnupg
    socat -d \
      "UNIX-LISTEN:/home/claude-cask/.gnupg/S.gpg-agent,fork,reuseaddr,user=claude-cask,group=claude-cask,mode=0600" \
      "UNIX-CONNECT:/run/host-gpg-agent" &
    # Wait briefly for the socket file to appear before dropping privileges.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [[ -S /home/claude-cask/.gnupg/S.gpg-agent ]] && break
      sleep 0.1
    done
  fi

  exec gosu claude-cask "$0" "$@"
fi

# === unprivileged section (runs as claude-cask) ===

KEY_PATH="${CLAUDE_CASK_KEY_PATH:-/tmp/signing-key.asc}"

if [[ -f "$KEY_PATH" && -n "${CLAUDE_CASK_SIGNING_KEY:-}" ]]; then
  mkdir -p "$HOME/.gnupg"
  chmod 700 "$HOME/.gnupg"

  gpg --batch --import "$KEY_PATH"
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
  cd /workspace
fi

exec claude "$@"
