# hello-worker

A complete PicoRuby MCP server on Cloudflare Workers, using Pavement from this
repository. It exposes:

- `hello`: a required string input and an optional boolean with a default.
- `sum`: integer inputs and a validated, structured output.
- `hello://about`: a text resource whose reader uses an instance method and the
  current Rack `env`.

## Run locally

Install Ruby 3.2 or later, Node.js supported by Wrangler, Emscripten (`emcc` and
`emar` on `PATH`), and a nightly Rust toolchain. Set `PICORUBY_ROOT` to a PicoRuby
checkout with initialized submodules. Run these commands in this directory:

```sh
rustup toolchain install nightly
rustup target add wasm32-unknown-emscripten --toolchain nightly
export PICORUBY_ROOT=/absolute/path/to/picoruby
bundle install
npm ci
bundle exec rake doctor
npm run dev
```

The first build compiles PicoRuby to Wasm and can take several minutes.
Wrangler builds the app before starting and serves `http://127.0.0.1:8787/mcp`.
The example uses no external service bindings; local tool calls need no
Cloudflare login. In another terminal, from this directory, run:

```sh
npm run test:dev
```

The smoke test discovers the server, lists and calls both tools, and reads the
resource over HTTP. To use another local port, run `npm run dev -- --port 8790`
and `MCP_URL=http://127.0.0.1:8790/mcp npm run test:dev`.

For a quick manual call using the supported 2025-11-25 protocol:

```sh
curl http://127.0.0.1:8787/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-11-25' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"hello","arguments":{"name":"PicoRuby"}}}'
```

The text result is `Hello, PicoRuby!`. MCP clients can connect to the same
endpoint; Pavement also supports the legacy `initialize` handshake.

## Project layout

`app.rb` defines the DSL and registers `Application` with the Cloudflare Rack
handler. `build_config.rb` includes the repository root as a local mgem, so
changes to Pavement are included when rebuilding. `src/index.js` loads the
generated runtime, app bytecode, and bindings. Do not edit `generated/`;
`npm run build` regenerates it. Wrangler watches the app, build configuration,
and Pavement's `mrblib/` directory.

## Deploy

Set `MCP_ALLOWED_HOSTS` in the Wrangler `vars` configuration to the public
hostname (without a scheme, path, or port). The default allows only `localhost`
and `127.0.0.1`. Then deploy with `npm run deploy` after authenticating with
Cloudflare. See [demo-tape](https://github.com/udzura/demo-tape#authentication-with-cloudflare-access)
for an example of protecting a deployed MCP server with Cloudflare Access.
