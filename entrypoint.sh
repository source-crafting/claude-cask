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
    # Docker Desktop on macOS presents the bind-mounted host socket as
    # root:root mode 660 inside the container. chown it to claude-cask so
    # the unprivileged user can connect, then symlink it to the standard
    # path in claude-cask's home. No long-running bridge process needed.
    install -d -m 700 -o claude-cask -g claude-cask /home/claude-cask/.gnupg
    chown claude-cask:claude-cask /run/host-gpg-agent
    ln -sfn /run/host-gpg-agent /home/claude-cask/.gnupg/S.gpg-agent
  fi

  # When --anthropic-only was passed, set up a kernel-enforced egress
  # restriction: an HTTPS proxy that allowlists api.anthropic.com, plus
  # iptables OUTPUT rules that block every other outbound except via the
  # proxy. The unprivileged claude-cask user can only reach the network
  # through the proxy, which only forwards to api.anthropic.com.
  if [[ "${CLAUDE_CASK_NETWORK_MODE:-}" == "anthropic-only" ]]; then
    cat > /etc/tinyproxy/tinyproxy.conf <<'EOF'
User tinyproxy
Group tinyproxy
Port 8888
Listen 127.0.0.1
Timeout 600
LogLevel Info
PidFile "/run/tinyproxy.pid"
MaxClients 100
Allow 127.0.0.1
Filter "/etc/tinyproxy/filter"
FilterDefaultDeny Yes
FilterExtended On
ConnectPort 443
EOF
    cat > /etc/tinyproxy/filter <<'EOF'
^api\.anthropic\.com$
EOF

    tinyproxy -c /etc/tinyproxy/tinyproxy.conf

    proxy_ready=0
    for _ in $(seq 1 50); do
      if (echo > /dev/tcp/127.0.0.1/8888) 2>/dev/null; then
        proxy_ready=1
        break
      fi
      sleep 0.1
    done
    if [[ $proxy_ready -eq 0 ]]; then
      echo "claude-cask: tinyproxy failed to start on 127.0.0.1:8888 within 5s" >&2
      exit 1
    fi
    # The poll only confirms that the listening socket appeared at some
    # point. tinyproxy could have accepted the probe and then crashed before
    # iptables takes effect, leaving us with restrictions but no proxy. Verify
    # the daemon is actually still alive via its pid file.
    if [[ ! -s /run/tinyproxy.pid ]] || ! kill -0 "$(cat /run/tinyproxy.pid)" 2>/dev/null; then
      echo "claude-cask: tinyproxy started but is no longer running" >&2
      exit 1
    fi

    # Block all non-loopback OUTPUT except: DNS, established connections,
    # and traffic from the tinyproxy daemon itself.
    iptables -P OUTPUT DROP
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m owner --uid-owner tinyproxy -j ACCEPT
  fi

  exec gosu claude-cask "$0" "$@"
fi

# Inherited proxy env so the unprivileged claude-cask user routes through
# the in-container proxy (which is the only path out under --anthropic-only).
if [[ "${CLAUDE_CASK_NETWORK_MODE:-}" == "anthropic-only" ]]; then
  export HTTPS_PROXY="http://127.0.0.1:8888"
  export HTTP_PROXY="http://127.0.0.1:8888"
  export NO_PROXY="localhost,127.0.0.1"
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
