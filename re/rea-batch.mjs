// Runs a batch of REA MCP tool calls in ONE live session (one Ghidra import).
// Usage: re/rea-batch.mjs <calls.json> [out.json]
//   calls.json: [{"tool": "open_binary", "args": {...}}, {"tool": "...", "args": {...}}, ...]
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
const here = dirname(fileURLToPath(import.meta.url));
const sdk = join(here, "tools/rea-ps2/node_modules/@modelcontextprotocol/client/dist");
const { Client } = await import(join(sdk, "index.mjs"));
const { StdioClientTransport } = await import(join(sdk, "stdio.mjs"));

const calls = JSON.parse(readFileSync(process.argv[2], "utf8"));
const transport = new StdioClientTransport({
  command: join(here, "rea"),
  args: ["mcp"],
  env: { ...process.env },
  stderr: "inherit",
});
const client = new Client({ name: "naruto-uc2-re", version: "1.0.0" });
await client.connect(transport);
const results = [];
if (calls.length === 0) {
  const tools = await client.listTools();
  results.push(tools.tools.map((t) => ({ name: t.name, description: t.description, input: t.inputSchema })));
}
for (const call of calls) {
  const started = Date.now();
  try {
    const r = await client.callTool({ name: call.tool, arguments: call.args ?? {} }, { timeout: 1_800_000 });
    const text = (r.content ?? []).filter((c) => c.type === "text").map((c) => c.text).join("\n");
    let parsed; try { parsed = JSON.parse(text); } catch { parsed = text; }
    results.push({ tool: call.tool, args: call.args, ms: Date.now() - started, isError: r.isError ?? false, result: r.structuredContent ?? parsed });
  } catch (e) {
    results.push({ tool: call.tool, args: call.args, ms: Date.now() - started, isError: true, result: String(e) });
  }
  process.stderr.write(`[rea-batch] ${call.tool} ${Date.now() - started}ms\n`);
}
const out = JSON.stringify(results, null, 1);
if (process.argv[3]) writeFileSync(process.argv[3], out); else process.stdout.write(out);
await client.close();
