/**
 * Minimal reproducer for "InstanceRef not provided" in OpenCode v1.15.x.
 *
 * Status as of v1.15.4: PR #28051 fixed the Bus.publish class of failures,
 * but the original cached-lookup issue in
 *   packages/opencode/src/effect/instance-state.ts:50-53
 * is still broken. PR #25694 (which fixes it) was never merged.
 *
 * Mechanism:
 *
 *   export const get = <A, E, R>(self: InstanceState<A, E, R>) =>
 *     Effect.gen(function* () {
 *       return yield* ScopedCache.get(self.cache, yield* directory)
 *     })
 *
 * ScopedCache.make({ lookup }) in make() at line 32-37 runs the lookup on a
 * detached fiber that does NOT inherit InstanceRef. So the FIRST cache miss
 * for any consumer of InstanceState.get(SomeStorage) dies with
 * "InstanceRef not provided".
 *
 * This plugin probes a sequence of SDK endpoints that walk into
 * InstanceState.get server-side. Each call is wrapped in try/catch and the
 * outcome (success message, or error containing "InstanceRef not provided")
 * is logged to /tmp/instanceref-repro.log.
 *
 * Expected (fixed): every probe succeeds.
 * Actual on v1.15.4: at least one probe fails with
 *   "InstanceRef not provided"
 * because the server endpoint hit a cache-miss on an InstanceState consumer.
 */

import fs from "node:fs";
import path from "node:path";

const logPath = path.join(process.env.TMPDIR || "/tmp", "instanceref-repro.log");
const log = (msg) => {
  fs.appendFileSync(logPath, `[${new Date().toISOString()}] ${msg}\n`);
};

log(`MODULE LOAD pid=${process.pid} import_meta_url=${import.meta.url}`);

let __invocation = 0;

const plugin = async (input) => {
  __invocation += 1;
  log(
    `plugin() invocation pid=${process.pid} invocation=#${__invocation} ` +
      `directory=${input?.directory ?? "<undef>"} ` +
      `client_typeof=${typeof input?.client}`,
  );

  const client = input?.client;
  if (!client) {
    log(`ERROR: input.client is not provided — cannot probe SDK endpoints`);
    return { tool: {} };
  }

  // Fire probes asynchronously so plugin() returns quickly. Each probe walks
  // into InstanceState.get for a different consumer.
  setTimeout(() => runProbes(client).catch((e) => log(`runProbes outer crash: ${e?.stack ?? e}`)), 100);

  return {
    tool: {
      __instanceref_repro_check: {
        description:
          "Probes OpenCode SDK endpoints to reproduce 'InstanceRef not provided' from " +
          "InstanceState.get cache-miss. Run this tool from any session and check " +
          "/tmp/instanceref-repro.log.",
        async execute() {
          await runProbes(client, { fromTool: true });
          return { output: `Probes complete. Check ${logPath}` };
        },
      },
    },
  };
};

async function runProbes(client, opts = {}) {
  const tag = opts.fromTool ? "tool" : "init";

  // Each probe hits a different server endpoint. The endpoints internally
  // use InstanceState.get(SomeStorage) for the first time per directory, so
  // they exercise the cache-miss lookup path.
  const probes = [
    { name: "app.log", fn: () => client.app.log({ body: { service: "repro", level: "info", message: "probe" } }) },
    { name: "session.list", fn: () => client.session.list() },
    { name: "find.files", fn: () => client.find.files({ query: { query: "*.md" } }) },
    { name: "file.status", fn: () => client.file.status() },
    { name: "config.providers", fn: () => client.config.providers() },
  ];

  for (const probe of probes) {
    try {
      const result = await probe.fn();
      const ok = result && typeof result === "object";
      const preview = ok ? JSON.stringify(result).slice(0, 80) : String(result);
      log(`PROBE ${tag} ${probe.name}: OK preview=${preview}`);
    } catch (err) {
      const msg = err?.message ?? String(err);
      const isInstanceRef = /InstanceRef not provided/.test(msg) || /InstanceRef not provided/.test(err?.stack ?? "");
      log(
        `PROBE ${tag} ${probe.name}: ERROR instance_ref_match=${isInstanceRef} ` +
          `message=${truncate(msg, 200)}`,
      );
      if (isInstanceRef) {
        log(`REPRODUCED: ${probe.name} returned "InstanceRef not provided"`);
      }
    }
  }
}

function truncate(s, n) {
  if (typeof s !== "string") s = String(s);
  return s.length > n ? s.slice(0, n) + "...[truncated]" : s;
}

export default plugin;
