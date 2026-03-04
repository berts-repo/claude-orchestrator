FROM node:20-slim

# Install @openai/codex globally
RUN npm install -g @openai/codex@0.104.0

# Codex writes cache/config here; ensure it's writable
RUN mkdir -p /root/.codex

# Default working directory (overridden at runtime via -w)
WORKDIR /workspace

ENTRYPOINT ["codex"]
