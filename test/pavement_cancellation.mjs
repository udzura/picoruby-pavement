import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import createPicoRuby from "../examples/hello-worker/generated/worker/runtime/picoruby-worker.js";
import { createCloudflareBindings, handleRequestWithOptions } from "../examples/hello-worker/generated/worker/runtime/runtime.js";

// Build examples/hello-worker first. All fetches below stay inside this process.
const project = new URL("../examples/hello-worker/", import.meta.url);
const wasm = await WebAssembly.compile(await readFile(new URL("generated/worker/runtime/picoruby-worker.wasm", project)));
const directory = await mkdtemp(join(tmpdir(), "pavement-cancellation-"));
const bytecodePath = join(directory, "app.bin");
let app;
try {
  execFileSync(fileURLToPath(new URL(".picoruby-build/mrbc/default/bin/mrbc", project)), [
    "-o", bytecodePath, fileURLToPath(new URL("fixtures/cancellation_app.rb", import.meta.url)),
  ]);
  app = await readFile(bytecodePath);
} finally {
  await rm(directory, { recursive: true });
}

async function run(mode, cancellation, legacy = false) {
  const calls = [];
  const started = Promise.withResolvers();
  const resume = Promise.withResolvers();
  const abort = new AbortController();
  let completion;
  globalThis.fetch = async (url) => {
    const step = new URL(url instanceof Request ? url.url : url).pathname.slice(1);
    calls.push(step);
    if (step === "start") {
      started.resolve();
      await resume.promise;
    }
    return new Response("ok");
  };
  const bindings = createCloudflareBindings({}, {});
  const meta = legacy ? {} : {
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities": {},
  };
  if (mode === "progress") meta.progressToken = "job";
  const request = new Request("http://localhost/mcp", {
    method: "POST",
    signal: abort.signal,
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json, text/event-stream",
      "MCP-Protocol-Version": legacy ? "2025-11-25" : "2026-07-28",
      "Mcp-Method": "tools/call",
      "Mcp-Name": "work",
    },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call",
      params: { name: "work", arguments: { mode }, _meta: meta } }),
  });
  const response = await handleRequestWithOptions(createPicoRuby, wasm, app, request,
    { ctx: { waitUntil(promise) { completion = promise; } } }, bindings);
  assert.equal(response.status, 200, response.status === 200 ? undefined : await response.text());
  assert.equal(response.headers.get("content-type"), "text/event-stream");
  const reader = response.body.getReader();
  const events = [];
  const drain = async () => {
    let text = "";
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      text += new TextDecoder().decode(value);
    }
    return text.split("\n\n").filter(Boolean).map((event) => JSON.parse(event.slice(6)));
  };
  if (mode === "progress") {
    const first = await reader.read();
    events.push(JSON.parse(new TextDecoder().decode(first.value).slice(6)));
    assert.equal(events[0].method, "notifications/progress");
    assert.equal(events[0].params.progress, 0);
  }
  await started.promise;
  if (cancellation === "reader") {
    await reader.cancel("client stopped");
  } else if (cancellation === "abort") {
    abort.abort(new Error("client stopped"));
    await assert.rejects(reader.read(), /client stopped/);
  }
  resume.resolve();
  if (!cancellation) events.push(...await drain());
  await completion;
  assert.deepEqual(calls, cancellation ? ["start", "cleanup"] : ["start", "after", "cleanup"]);
  if (!cancellation) {
    const result = events.at(-1).result;
    assert.equal(result.content[0].text, "done");
    assert.equal(result.isError, false);
    assert.equal(events.length, mode === "progress" ? 3 : 1);
  }
  reader.releaseLock();
}

// A bounded run catches hangs in host writes or VM cleanup without timing assertions.
const timeout = setTimeout(() => {
  console.error("Cancellation integration test timed out");
  process.exit(1);
}, 30_000);
const originalFetch = globalThis.fetch;
try {
  for (const legacy of [false, true]) {
    for (const mode of ["checkpoint", "poll", "progress"]) {
      await run(mode, "reader", legacy);
      await run(mode, "abort", legacy);
      await run(mode, null, legacy);
    }
  }
  console.log("Pavement Wasm cancellation test passed");
} finally {
  globalThis.fetch = originalFetch;
  clearTimeout(timeout);
}
