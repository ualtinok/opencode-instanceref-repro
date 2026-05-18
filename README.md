# OpenCode `InstanceRef not provided` reproducer

A self-contained Docker repro for the runtime error every OpenCode plugin
hits when it calls `ctx.ask(...)` on OpenCode **1.15.4+**. PR
[#28051](https://github.com/anomalyco/opencode/pull/28051) cleaned up
`Bus.publish` in fibers but did NOT touch the cached lookup in
`InstanceState.get`, which is where this error originates.

## TL;DR

| Component | Version |
| --- | --- |
| OpenCode | 1.15.4 (default ARG; bug also reproduces on `dev`) |
| Affected line | `packages/opencode/src/effect/instance-state.ts:50-53` |
| Plugin | a hand-written 50-line plugin in `plugin/index.js` — no real-world plugins involved |
| LLM | aimock, scripted to call the plugin tool once |

Every plugin that gates work behind `ctx.ask(...)` — read, write, edit, bash,
grep, glob, custom permission tools — fails identically. The error text is
literally `"InstanceRef not provided"`.

## Run it

```bash
docker build -t opencode-instanceref-repro .
docker run --rm opencode-instanceref-repro
```

Expected tail of output:

```
=== Summary ===
InstanceRef matches in stdout: 0
InstanceRef matches in stderr: 3
REPRODUCED: "InstanceRef not provided" surfaced during a normal plugin permission ask.
```

Exit code `0` = reproduced.

## What it actually does

1. Installs `opencode-ai@1.15.4`, `@copilotkit/aimock@1.24.0`, Node 24.
2. Drops a 50-line plugin at `/repro/plugin/index.js` that registers a
   single tool named `bash` (overriding OpenCode's built-in by name).
   The tool's `execute` callback does:

   ```js
   await Effect.runPromise(
     context.ask({ permission: "edit", patterns: ["**/*"], always: ["*"], metadata: {} })
   );
   ```

   The plugin imports `tool` from `@opencode-ai/plugin` (NOT from the
   `PluginInput` destructure — that input has no `tool` property in
   1.15.4, so destructuring it silently kills plugin registration).

3. Registers aimock as an OpenAI-compatible provider in
   `~/.config/opencode/opencode.json`.
4. The driver script starts aimock, runs `opencode run "..."`, aimock
   answers the first turn with a tool call to `bash`, opencode dispatches
   to the plugin's `bash` (since later registrations overwrite earlier
   ones in `session/prompt.ts` `tools[item.id] = ...`), and the
   `await Effect.runPromise(...)` throws.
5. The driver greps the run output for `"InstanceRef not provided"` and
   exits 0 on match.

### Caveat about plugin shape

Plugin tool registration is finicky. The plugin's default export must:
- Be `async function(input) { ... }` — destructuring `{ tool }` from
  input does NOT work; the input object has no `tool`. Import `tool`
  from `@opencode-ai/plugin` separately.
- Use `tool({...})` from `@opencode-ai/plugin` for every entry. Plain
  objects work in some code paths but the official path is via the
  helper, which keeps Zod schemas correctly typed.
- Match the built-in tool's `args` shape closely when overriding (otherwise
  the LLM's call fails schema validation BEFORE hitting your execute).

## Bug mechanism

The Effect returned from `context.ask(...)` resolves permission policy by
walking through OpenCode's `InstanceState` consumers. On a cache miss,
`InstanceState.get` schedules its `ScopedCache.lookup` on a fiber that does
**not** inherit the host's `InstanceRef` service:

```ts
// packages/opencode/src/effect/instance-state.ts:50-53 — current
export const get = <A, E, R>(self: InstanceState<A, E, R>) =>
  Effect.gen(function* () {
    return yield* ScopedCache.get(self.cache, yield* directory)
  })
```

`ScopedCache.make({ lookup })` (line 32-37) declares `lookup` as
`() => Effect.gen(function* () { yield* context })`. When `ScopedCache.get`
hits a miss it runs that lookup; the lookup's `yield* context` then fails
because no `InstanceRef` is provided in the cache-miss fiber's environment.

## Fix

Wrap the `ScopedCache` operation so it executes with `InstanceRef`
re-provided:

```ts
export const get = <A, E, R>(self: InstanceState<A, E, R>) =>
  Effect.gen(function* () {
    const ctx = yield* context
    return yield* ScopedCache.get(self.cache, ctx.directory).pipe(
      Effect.provideService(InstanceRef, ctx),
    )
  })
```

`has()` (line 62-65) and `invalidate()` (line 67-70) have the same broken
pattern and should receive the same wrap preventatively, but they are cold
paths — only `get()` causes user-visible plugin failures today.

## Why this is OpenCode-side

The error text is produced by OpenCode's own service-resolution layer, not
by any plugin code. Every plugin observed today does the standard pattern:

```js
await Effect.runPromise(context.ask({...}));
```

That pattern is what OpenCode's own internal permission handlers use too.
There is no plugin-side workaround that doesn't either silently bypass the
user's permission rules (security regression) or stop using `ctx.ask`
entirely (which means the plugin is no longer compatible with OpenCode's
permission system).
