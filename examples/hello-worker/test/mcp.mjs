import assert from "node:assert/strict";

const url = process.env.MCP_URL || "http://127.0.0.1:8787/mcp";
const version = "2026-07-28";
let nextId = 1;

async function request(method, params = {}) {
  const headers = {
    "Content-Type": "application/json",
    Accept: "application/json, text/event-stream",
    "MCP-Protocol-Version": version,
    "Mcp-Method": method,
  };
  if (params.name || params.uri) headers["Mcp-Name"] = params.name || params.uri;
  const response = await fetch(url, {
    method: "POST",
    headers,
    signal: AbortSignal.timeout(10_000),
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: nextId++,
      method,
      params: {
        ...params,
        _meta: {
          "io.modelcontextprotocol/protocolVersion": version,
          "io.modelcontextprotocol/clientCapabilities": {},
        },
      },
    }),
  });
  const body = await response.json();
  assert.equal(response.status, 200, JSON.stringify(body));
  assert.equal(body.error, undefined);
  return body.result;
}

const discovery = await request("server/discover");
assert.equal(discovery._meta["io.modelcontextprotocol/serverInfo"].name, "pavement-hello-worker");

const tools = await request("tools/list");
assert.deepEqual(tools.tools.map((tool) => tool.name), ["hello", "sum"]);

const hello = await request("tools/call", { name: "hello", arguments: { name: "PicoRuby" } });
assert.equal(hello.content[0].text, "Hello, PicoRuby!");
const shouted = await request("tools/call", { name: "hello", arguments: { name: "PicoRuby", shout: true } });
assert.equal(shouted.content[0].text, "HELLO, PICORUBY!");

const sum = await request("tools/call", { name: "sum", arguments: { left: 2, right: 3 } });
assert.deepEqual(sum.structuredContent, { sum: 5 });
assert.deepEqual(JSON.parse(sum.content[0].text), { sum: 5 });

const resources = await request("resources/list");
assert.equal(resources.resources[0].uri, "hello://about");
const about = await request("resources/read", { uri: "hello://about" });
assert.match(about.contents[0].text, /PicoRuby MCP server/);
assert.ok(about.contents[0].text.endsWith(`Host: ${new URL(url).host}`));

console.log("hello-worker MCP smoke test passed");
