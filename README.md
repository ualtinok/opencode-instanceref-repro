# OpenCode `InstanceRef not provided` reproducer

A ~100-line reproducer showing that **`InstanceState.get`'s cached lookup
in OpenCode v1.15.4 still dies with `InstanceRef not provided`**, despite
PR #28051 having landed.

> Originally surfaced while debugging
> [`@cortexkit/aft-opencode`](https://github.com/cortexkit/aft) bash failures
> on OpenCode v1.15.x.

## TL;DR

- PR [#28051](https://github.com/anomalyco/opencode/pull/28051) fixed
  `Bus.publish` from detached fibers (Class 2 in the original handoff).
  Shipped in **v1.15.4**.
- The original cached-lookup issue (Class 1, identified in PR
  [#25694](https://github.com/anomalyco/opencode/pull/25694)) is **still
  unfixed** at `packages/opencode/src/effect/instance-state.ts:50-53`:

  ```ts
  export const get = <A, E, R>(self: InstanceState<A, E, R>) =>
    Effect.gen(function* () {
      return yield* ScopedCache.get(self.cache, yield* directory)
    })
  ```

- `ScopedCache.make({ lookup })` (in `make()` at lines 32-37) runs `lookup`
  on a fiber that does **NOT** inherit `InstanceRef`, so the FIRST cache
  miss for any `InstanceState.get(SomeStorage)` dies with
  `InstanceRef not provided`.
- `has()` (lines 62-65) and `invalidate()` (67-70) have the same broken
  pattern but are cold paths today.

## Why this matters

Any plugin that calls the OpenCode SDK from inside a tool handler — or any
internal server endpoint that walks into `InstanceState.get` — can throw
`InstanceRef not provided` on first call per directory.

For AFT specifically, this breaks bash:

- AFT's hoisted `bash` calls `client.session.get(sessionID)` on first session
  call (subagent detection).
- AFT's background-bash completion calls `client.session.promptAsync(...)`
  to wake the agent.
- Both server endpoints walk into `InstanceState.get(SomeStorage)`, hit the
  cache miss, run `lookup` on a detached fiber, and die.

End-user symptom: bash tool calls hang and time out at the plugin transport
timeout (30s) on v1.15.x.

## Recommended fix

Revive PR #25694 (or land an equivalent change). Wrap the cache call with
`Effect.provideService(InstanceRef, ctx)`:

```ts
// packages/opencode/src/effect/instance-state.ts:50-53
export const get = <A, E, R>(self: InstanceState<A, E, R>) =>
  Effect.gen(function* () {
    const ctx = yield* context
    return yield* ScopedCache.get(self.cache, ctx.directory).pipe(
      Effect.provideService(InstanceRef, ctx),
    )
  })
```

Apply the same wrap to `has()` (62-65) and `invalidate()` (67-70).

## How to reproduce

### Docker one-command repro

```bash
docker build -t opencode-instanceref-repro .
docker run --rm opencode-instanceref-repro
```

The container installs `opencode-ai@1.15.4`, registers this plugin, starts
OpenCode briefly, runs five SDK probes from the plugin (`app.log`,
`session.list`, `find.files`, `file.status`, `config.providers`), captures
errors, and exits successfully when at least one probe surfaces
`InstanceRef not provided` — either in the SDK error message it gets back,
or in OpenCode's own stderr.

Override the version to test a fixed build:

```bash
docker build --build-arg OPENCODE_VERSION=1.15.10 -t opencode-instanceref-repro .
docker run --rm opencode-instanceref-repro
```

### Manual repro

1. Add this plugin to your OpenCode config:

   ```jsonc
   // ~/.config/opencode/opencode.jsonc
   {
     "plugin": [
       "file:///absolute/path/to/opencode-instanceref-repro"
     ]
   }
   ```

2. Clear the log:

   ```bash
   rm -f "${TMPDIR:-/tmp}/instanceref-repro.log"
   # or: npm run clean-log
   ```

3. Start OpenCode in any project. The plugin runs five SDK probes
   asynchronously during init. Wait ~5s.

4. Read the log:

   ```bash
   cat "${TMPDIR:-/tmp}/instanceref-repro.log"
   # or: npm run show-log
   ```

5. Optionally, ask the model to call the `__instanceref_repro_check` tool —
   that re-runs the probe sequence with `PROBE tool` log lines, useful for
   reproducing the failure from a real tool-execution path (which is what
   AFT bash hits).

## Expected vs actual output

### ✅ Expected (fixed)

Every probe succeeds:

```
[t0] MODULE LOAD pid=... import_meta_url=file:///repro/src/index.js
[t1] plugin() invocation pid=... invocation=#1 directory=/work/project client_typeof=object
[t2] PROBE init app.log: OK preview={...}
[t3] PROBE init session.list: OK preview=[...]
[t4] PROBE init find.files: OK preview=[...]
[t5] PROBE init file.status: OK preview=[...]
[t6] PROBE init config.providers: OK preview=[...]
```

### ❌ Actual (observed on v1.15.4)

At least one probe fails with `instance_ref_match=true` and at least one
`REPRODUCED:` line, e.g.:

```
[t0] MODULE LOAD ...
[t1] plugin() invocation invocation=#1 directory=/work/project client_typeof=object
[t2] PROBE init app.log: OK ...
[t3] PROBE init session.list: ERROR instance_ref_match=true message=InstanceRef not provided
[t4] REPRODUCED: session.list returned "InstanceRef not provided"
...
```

Or — if the server-side dies but the SDK call returns a generic error —
`InstanceRef not provided` appears in OpenCode's stderr (captured in the
script summary at the end).

## Cleanup

Remove the plugin entry from your OpenCode config:

```jsonc
{
  "plugin": [
    // remove this line:
    // "file:///absolute/path/to/opencode-instanceref-repro"
  ]
}
```

Optionally remove the log:

```bash
rm -f "${TMPDIR:-/tmp}/instanceref-repro.log"
```

## Files

- `src/index.js` — plugin with five SDK probes (~120 lines)
- `Dockerfile` — pins `opencode-ai@1.15.4`, installs the plugin
- `reproduce-instanceref.sh` — entrypoint that runs OpenCode + the probes
  and exits 0 only when reproduced
- `package.json` — declares `oc-plugin: ["server"]`
- `README.md` — this document
