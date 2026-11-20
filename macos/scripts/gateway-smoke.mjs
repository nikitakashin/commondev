// Run against a local sidecar without printing its authentication token.
import { readFile } from "node:fs/promises";

const controlPath = process.argv[2];
if (!controlPath) throw new Error("Usage: node gateway-smoke.mjs <control-file>");
const ready = JSON.parse(await readFile(controlPath, "utf8"));
const base = `http://127.0.0.1:${ready.port}`;
const headers = { authorization: `Bearer ${ready.token}`, "content-type": "application/json" };
const modelsResponse = await fetch(base + "/v1/models", { headers });
console.log("Model catalog HTTP", modelsResponse.status);
const models = await modelsResponse.json();
console.log("Models available", Array.isArray(models.data) ? models.data.length : 0);
const response = await fetch(base + "/v1/chat/completions", {
  method: "POST",
  headers,
  signal: AbortSignal.timeout(90_000),
  body: JSON.stringify({
    model: "auto",
    messages: [{ role: "user", content: "Call the add_numbers function with a=2 and b=3." }],
    tools: [{
      type: "function",
      function: {
        name: "add_numbers",
        description: "Add two integers",
        parameters: {
          type: "object",
          properties: { a: { type: "integer" }, b: { type: "integer" } },
          required: ["a", "b"],
        },
      },
    }],
    tool_choice: "required",
    max_tokens: 250,
  }),
});
console.log("Tool call HTTP", response.status);
const result = await response.json();
const calls = result.choices?.[0]?.message?.tool_calls;
console.log("Tool call received", Array.isArray(calls) && calls.length > 0);
if (!response.ok || !Array.isArray(calls) || calls.length === 0) {
  console.log("Provider response", JSON.stringify(result.error ?? result).slice(0, 1200));
  process.exitCode = 1;
}
