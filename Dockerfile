FROM node:24-bookworm-slim

# Pinned to v1.15.4 — first release containing PR #28051 (Bus.publish fix).
# PR #25694 (the InstanceState.get cached-lookup fix) was NEVER merged, so
# v1.15.4 still exhibits the cache-miss "InstanceRef not provided" failure.
ARG OPENCODE_VERSION=1.15.4

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates coreutils \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g "opencode-ai@${OPENCODE_VERSION}" \
    && opencode --version

WORKDIR /repro
COPY package.json README.md ./
COPY src ./src

RUN mkdir -p /root/.config/opencode /work/project \
    && printf '%s\n' \
    '{' \
    '  "plugin": [' \
    '    "file:///repro"' \
    '  ]' \
    '}' \
    > /root/.config/opencode/opencode.jsonc

COPY reproduce-instanceref.sh /usr/local/bin/reproduce-instanceref
RUN chmod +x /usr/local/bin/reproduce-instanceref

ENV OPENCODE_DISABLE_AUTOUPDATE=1 \
    OPENCODE_DISABLE_PROJECT_CONFIG=1 \
    TERM=xterm-256color

CMD ["reproduce-instanceref"]
