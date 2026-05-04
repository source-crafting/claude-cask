FROM node:24.15.0-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git \
      gnupg \
      ca-certificates \
      curl \
      openssh-client \
      gosu \
      tinyproxy \
      iptables \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Create a non-root user 'claude-cask' with a UID/GID supplied at build time
# (defaulting to 1000). The launcher passes the host user's UID/GID so that
# bind-mounted files are owned by the same UID inside the container as on
# the host — important on native Linux where docker preserves UIDs literally.
# On Docker Desktop / macOS, virtiofs translates UIDs anyway, but matching
# the host UID is still the right default.
ARG USER_UID=1000
ARG USER_GID=1000

# Hash of (Dockerfile + entrypoint.sh) — i.e., everything in the build
# context per .dockerignore. The launcher computes this hash at every
# invocation, passes it via --build-arg, and inspects the label below
# to decide whether the image is stale relative to the source. Empty
# by default so direct `docker build` invocations don't fail.
ARG IMAGE_HASH=""

# Bake the metadata into image labels so the launcher can detect when
# a rebuild is needed (UID/GID drift after switching machines, source
# drift after editing Dockerfile or entrypoint).
LABEL claude-cask.uid="${USER_UID}"
LABEL claude-cask.gid="${USER_GID}"
LABEL claude-cask.image-hash="${IMAGE_HASH}"

# Free up the requested UID/GID by removing whichever user/group currently
# owns it (e.g., the base image's `node` user at UID 1000), then create
# claude-cask. Pre-create the home dotdirs that get bind-mounted into so
# they exist as mountpoints owned by claude-cask before mounts are applied.
RUN set -e \
 && existing_user="$(getent passwd "${USER_UID}" | cut -d: -f1)" \
 && [ -n "$existing_user" ] && userdel --remove "$existing_user" 2>/dev/null || true \
 && existing_group="$(getent group "${USER_GID}" | cut -d: -f1)" \
 && [ -n "$existing_group" ] && groupdel "$existing_group" 2>/dev/null || true \
 && groupadd --gid "${USER_GID}" claude-cask \
 && useradd --create-home --shell /bin/bash --uid "${USER_UID}" --gid "${USER_GID}" claude-cask \
 && mkdir -p /home/claude-cask/.gnupg /home/claude-cask/.claude /workspace \
 && chmod 700 /home/claude-cask/.gnupg \
 && chown -R claude-cask:claude-cask /home/claude-cask /workspace

# Entrypoint runs as root briefly to set up a gpg-agent socket bridge (so the
# in-container claude-cask user can talk to the host's gpg-agent through a
# bind-mount that Docker Desktop presents as root-owned), then drops to
# claude-cask via gosu before exec'ing claude. WORKDIR remains /workspace.
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
