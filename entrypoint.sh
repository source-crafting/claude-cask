#!/usr/bin/env bash
set -euo pipefail

KEY_PATH="${CLAUDE_CASK_KEY_PATH:-/tmp/signing-key.asc}"

if [[ -f "$KEY_PATH" && -n "${CLAUDE_CASK_SIGNING_KEY:-}" ]]; then
  mkdir -p "$HOME/.gnupg"
  chmod 700 "$HOME/.gnupg"

  gpg --batch --import "$KEY_PATH"
  rm -f "$KEY_PATH"

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
