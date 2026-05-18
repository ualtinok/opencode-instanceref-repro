#!/usr/bin/env node
// Minimal aimock provider for the InstanceRef repro.
//
// Listens on http://127.0.0.1:4010/v1 and answers chat completions:
//   - The first turn (user message) → respond with a tool call to `repro_check`
//   - Any later turn (tool result follow-up) → respond with plain text "Done."
const { LLMock } = require("@copilotkit/aimock");

const port = parseInt(process.env.AIMOCK_PORT || "4010", 10);

async function main() {
  const mock = new LLMock({ port });

  // Match the very first user message (turn 0). Returns a tool_call so
  // opencode executes our plugin's `repro_check` tool. The Effect inside
  // that tool's execute callback is what hits the InstanceRef bug.
  mock.onTurn(
    0,
    /.*/,
    {
      toolCalls: [
        {
          name: "bash",
          arguments: JSON.stringify({
            command: "echo probe",
            description: "InstanceRef probe",
          }),
        },
      ],
    },
    { streamingProfile: { ttft: 50, tps: 100 } },
  );

  // Any later turn (the tool-result follow-up) just says "Done." so
  // opencode's run loop can terminate cleanly.
  mock.onMessage(
    /.*/,
    { content: "Done." },
    { streamingProfile: { ttft: 50, tps: 100 } },
  );

  await mock.start();
  console.log(`[aimock] listening on ${mock.url}`);

  const shutdown = async () => {
    await mock.stop();
    process.exit(0);
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

main().catch((e) => {
  console.error("[aimock] fatal:", e);
  process.exit(1);
});
