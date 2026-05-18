FROM debian:bookworm-slim

# ---------------------------------------------------------------------------
# Minimal reproducer for the "InstanceRef not provided" runtime error every
# plugin hits when calling `ctx.ask(...)` on OpenCode 1.15.4+.
#
# We deliberately install NO real-world plugins (no AFT, no anything). The
# repro is a hand-written 50-line plugin whose only job is to call
# `Effect.runPromise(context.ask({...}))` from inside a tool execute callback.
#
# Real impact: every plugin in the ecosystem that gates work behind a
# permission ask (read, write, edit, bash, grep, glob, ...) fails for end
# users on the new OpenCode line. The error surfaces inside the Effect
# returned by `context.ask(...)` because the cached lookup in
#   packages/opencode/src/effect/instance-state.ts:50-53
# runs on a fiber that has no InstanceRef in scope. PR #28051 (v1.15.4)
# cleaned up `Bus.publish` in fibers but did NOT touch this path.
# ---------------------------------------------------------------------------

ARG OPENCODE_VERSION=1.15.4

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       curl ca-certificates coreutils git \
    && rm -rf /var/lib/apt/lists/*

# Node 24 (for opencode + aimock + the tiny repro plugin).
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# OpenCode.
RUN npm install -g "opencode-ai@${OPENCODE_VERSION}" \
    && opencode --version

# aimock — OpenAI-compatible mock LLM. Pinned to 1.24.0 which exposes
# the cleaner `onTurn(turn, pattern, response)` + `onMessage(pattern, ...)`
# fixture API we use below.
RUN npm install -g @copilotkit/aimock@1.24.0

# Git config — opencode wants git for some session paths.
RUN git config --global user.email "test@example.com" \
    && git config --global user.name "Test"

# Empty git-tracked workspace so opencode has something to attach to.
RUN mkdir -p /work/project && cd /work/project \
    && git init -q \
    && echo '{"name":"test","version":"1.0.0"}' > package.json \
    && git add -A && git commit -q -m "init"

# Install the minimal repro plugin into /repro.
WORKDIR /repro
COPY plugin/package.json /repro/plugin/package.json
COPY plugin/index.js /repro/plugin/index.js
RUN cd /repro/plugin && npm install --no-audit --no-fund

# OpenCode config: register the local plugin + the aimock provider.
RUN mkdir -p /root/.config/opencode \
    && printf '%s\n' \
    '{' \
    '  "$schema": "https://opencode.ai/config.json",' \
    '  "plugin": ["file:///repro/plugin"],' \
    '  "provider": {' \
    '    "mock": {' \
    '      "api": "openai",' \
    '      "name": "aimock",' \
    '      "options": { "baseURL": "http://127.0.0.1:4010/v1", "apiKey": "test-key" },' \
    '      "models": {' \
    '        "mock-model": { "name": "Mock Model" }' \
    '      }' \
    '    }' \
    '  }' \
    '}' \
    > /root/.config/opencode/opencode.json

# Driver + scripted mock.
COPY mock-server.js /usr/local/bin/instanceref-mock-server.js
COPY reproduce-instanceref.sh /usr/local/bin/reproduce-instanceref
RUN chmod +x /usr/local/bin/reproduce-instanceref

ENV NODE_PATH="/usr/lib/node_modules" \
    OPENCODE_DISABLE_AUTOUPDATE=1 \
    TERM=xterm-256color

WORKDIR /work/project

CMD ["reproduce-instanceref"]
