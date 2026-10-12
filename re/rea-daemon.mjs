// Keeps one REA MCP session (one live Ghidra database) open and serves tool calls on 127.0.0.1.
// Usage: node re/rea-daemon.mjs <binary> [port=7391]
//   curl -s localhost:7391/call -d '{"tool":"procedure_pseudo_code","args":{"procedure":"0x1296b0"}}'
import { createServer } from "node:http";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
const here = dirname(fileURLToPath(import.meta.url));
const sdk = join(here, "tools/rea-ps2/node_modules/@modelcontextprotocol/client/dist");
const { Client } = await import(join(sdk, "index.mjs"));
const { StdioClientTransport } = await import(join(sdk, "stdio.mjs"));

const binary = resolve(process.argv[2]);
const port = Number(process.argv[3] ?? 7391);
const client = new Client({ name: "naruto-uc2-re-daemon", version: "1.0.0" });
await client.connect(new StdioClientTransport({ command: join(here, "rea"), args: ["mcp"], env: { ...process.env }, stderr: "inherit" }));

const call = async (tool, args) => {
  const r = await client.callTool({ name: tool, arguments: args ?? {} }, { timeout: 3_600_000 });
  const text = (r.content ?? []).filter((c) => c.type === "text").map((c) => c.text).join("\n");
  let parsed; try { parsed = JSON.parse(text); } catch { parsed = text; }
  return { isError: r.isError ?? false, result: r.structuredContent ?? parsed };
};
await call("open_binary", { path: binary, provider_id: "ghidra" });
// Warm up: first query waits for Ghidra auto-analysis.
await call("binary_overview", {});
process.stderr.write(`[rea-daemon] ready on ${port} for ${binary}\n`);

let queue = Promise.resolve();
createServer((req, res) => {
  let body = "";
  req.on("data", (d) => (body += d));
  req.on("end", () => {
    queue = queue.then(async () => {
      try {
        const { tool, args } = JSON.parse(body);
        const out = await call(tool, args);
        res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(out));
      } catch (e) {
        res.writeHead(500).end(JSON.stringify({ isError: true, result: String(e) }));
      }
    });
  });
}).listen(port, "127.0.0.1");
