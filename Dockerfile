FROM node:24-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git \
      gnupg \
      ca-certificates \
      openssh-client \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
