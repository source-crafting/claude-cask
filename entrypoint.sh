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
    # socat must run as root: the bind-mounted host socket is presented by
    # Docker Desktop as root:root mode 660 inside the container, and the
    # claude-cask user is not in the root group. Listening side is set up
    # with explicit ownership/mode so the dropped-privilege user can connect.
    socat \
      "UNIX-LISTEN:/home/claude-cask/.gnupg/S.gpg-agent,fork,reuseaddr,user=claude-cask,group=claude-cask,mode=0600" \
      "UNIX-CONNECT:/run/host-gpg-agent" &
    # Wait up to 5 seconds for the bridge socket to appear; fail loud if not.
    bridge_ready=0
    for _ in $(seq 1 50); do
      if [[ -S /home/claude-cask/.gnupg/S.gpg-agent ]]; then
        bridge_ready=1
        break
      fi
      sleep 0.1
    done
    if [[ $bridge_ready -eq 0 ]]; then
      echo "claude-cask: gpg-agent socket bridge failed to start within 5s" >&2
      exit 1
    fi
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
  cd /workspace
fi

exec claude "$@"
