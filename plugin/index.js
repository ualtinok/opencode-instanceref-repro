// Minimal repro plugin for the "InstanceRef not provided" runtime error.
//
// The plugin registers ONE tool: `repro_check`. Its execute callback calls
// `Effect.runPromise(context.ask({...}))` — exactly the pattern any plugin
// uses to ask OpenCode for a permission decision.
//
// On OpenCode 1.15.4+ this throws `InstanceRef not provided` from
// `packages/opencode/src/effect/instance-state.ts:50-53` because the cached
// lookup runs in a fiber that doesn't inherit the host's `InstanceRef`
// service. On 1.14.x and earlier it resolves cleanly (no auth/permission
// rules configured → silent "allow").
import { Effect } from "effect";
import { tool } from "@opencode-ai/plugin";

const log = (...a) => {
  console.error("[repro-plugin]", ...a);
};

export default async function reproPlugin() {
  log("plugin loaded");
  return {
    tool: {
      // We override the built-in `bash` tool name so the build agent
      // exposes it to the model. The actual command argument is ignored;
      // the body just calls ctx.ask to probe the InstanceRef path.
      bash: tool({
        description:
          "Triggers a permission ask via Effect.runPromise(ctx.ask(...)). " +
          "Returns 'OK' when the ask resolves cleanly, or surfaces the underlying " +
          "InstanceRef error when the cache-miss bug fires.",
        args: {
          // Accept the command + description args to match opencode's
          // built-in bash schema (otherwise SchemaError on missing keys).
          command: tool.schema.string().optional(),
          description: tool.schema.string().optional(),
          timeout: tool.schema.number().optional(),
        },
        execute: async (_args, context) => {
          log("execute() entered");
          if (typeof context.ask !== "function") {
            return "ERROR: context.ask is not a function (wrong host?)";
          }
          let askEffect;
          try {
            askEffect = context.ask({
              permission: "edit",
              patterns: ["**/*"],
              always: ["*"],
              metadata: {},
            });
            log("ctx.ask returned, Effect.runPromise next");
          } catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            return `ERROR (from ctx.ask itself): ${msg}`;
          }
          try {
            await Effect.runPromise(askEffect);
            return "OK: permission ask resolved cleanly (bug NOT reproduced)";
          } catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            const stack = err instanceof Error ? (err.stack ?? "") : "";
            log(`Effect.runPromise threw: ${msg}`);
            log(`stack: ${stack.slice(0, 600)}`);
            // Surface as a normal tool result string so the agent (mock LLM)
            // gets the failure text in its tool message and we can grep the
            // session transcript afterwards. The InstanceRef bug propagates
            // as the message text verbatim.
            return `ERROR (from Effect.runPromise): ${msg}`;
          }
        },
      }),
    },
  };
}
