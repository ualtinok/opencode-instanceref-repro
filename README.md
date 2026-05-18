# OpenCode `InstanceRef not provided` reproducer

Self-contained Docker repro for the runtime error every plugin hits when
`context.ask(...)` resolves on OpenCode **1.15.4+**. PR
[#28051](https://github.com/anomalyco/opencode/pull/28051) cleaned up
`Bus.publish` from detached fibers but did NOT touch the cached lookup in
`InstanceState.get`, which is where this error originates.

## Run

```bash
docker build -t opencode-instanceref-repro .
docker run --rm opencode-instanceref-repro
```

Expected tail:

```
=== Summary ===
InstanceRef matches in stdout: 0
InstanceRef matches in stderr: 3
REPRODUCED: "InstanceRef not provided" surfaced during a normal plugin permission ask.
```

Exit `0` = reproduced. ~25s end to end.

## How it works

A hand-written plugin (`plugin/index.js`, ~50 lines) registers one tool
whose `execute` callback does:

```js
await Effect.runPromise(
  context.ask({ permission: "edit", patterns: ["**/*"], always: ["*"], metadata: {} })
);
```

aimock drives a single tool call into that tool. The Effect throws
`InstanceRef not provided` at runtime; the driver script greps for it.

## Bug mechanism

The Effect returned from `context.ask(...)` walks `InstanceState`
consumers as part of permission resolution. On a cache miss,
`InstanceState.get` schedules its `ScopedCache.lookup` on a fiber that
does **not** inherit the host's `InstanceRef` service:

```ts
// packages/opencode/src/effect/instance-state.ts:50-53 — current
export const get = <A, E, R>(self: InstanceState<A, E, R>) =>
  Effect.gen(function* () {
    return yield* ScopedCache.get(self.cache, yield* directory)
  })
```

`ScopedCache.make({ lookup })` (line 32-37) declares `lookup` as
`() => Effect.gen(function* () { yield* context })`. When `ScopedCache.get`
hits a miss it runs that lookup; the lookup's `yield* context` fails because
no `InstanceRef` is in scope on the cache-miss fiber.

Stack trace from the repro:

```
Error: InstanceRef not provided
    at <anonymous> (/$bunfs/root/chunk-5cfj66ea.js:679:76275)
    at ~effect/Effect/successCont (/$bunfs/root/chunk-658twvfx.js:25:7736)
    at runLoop (.../effect/dist/internal/effect.js:444:98)
    at evaluate (.../effect/dist/internal/effect.js:412:23)
```

## Suggested fix

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
pattern and should receive the same wrap preventatively. Only `get()`
causes user-visible plugin failures today.

## Why this is OpenCode-side

The error text is produced by OpenCode's own service-resolution layer.
Plugins do the standard pattern:

```js
await Effect.runPromise(context.ask({...}));
```

That's the only way to run the Effect that `context.ask(...)` returns —
plain `await` resolves to the Effect object without executing it. There
is no plugin-side workaround that doesn't either silently bypass user
permission rules or stop using `ctx.ask` entirely.
