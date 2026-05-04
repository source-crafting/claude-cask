FROM node:24-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git \
      gnupg \
      ca-certificates \
      openssh-client \
      socat \
      gosu \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Create a non-root user 'claude-cask' (UID 1000). The base node:24-slim image
# ships a 'node' user at UID 1000; remove it and reuse the slot. Pre-create
# the home dotdirs that get bind-mounted into so they exist as mountpoints
# owned by claude-cask before mounts are applied.
RUN userdel --remove node 2>/dev/null || true \
 && useradd --create-home --shell /bin/bash --uid 1000 claude-cask \
 && mkdir -p /home/claude-cask/.gnupg /home/claude-cask/.claude /workspace \
 && chmod 700 /home/claude-cask/.gnupg \
 && chown -R claude-cask:claude-cask /home/claude-cask /workspace

# Entrypoint runs as root briefly to set up a gpg-agent socket bridge (so the
# in-container claude-cask user can talk to the host's gpg-agent through a
# bind-mount that Docker Desktop presents as root-owned), then drops to
# claude-cask via gosu before exec'ing claude. WORKDIR remains /workspace.
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
