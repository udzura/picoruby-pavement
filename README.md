# picoruby-pavement

> “You call to me.”
> — Pavement, [“Nigel”](https://pavement.bandcamp.com/track/nigel-unreleased-song)

Pavement is a small Ruby DSL for MCP servers on PicoRuby. It handles JSON-RPC
requests over Streamable HTTP and exposes tools and resources through a Rack
application. The gem depends on `mruby-jsonrs` for JSON parsing and generation.

## Add to a build

```ruby
conf.gem github: "udzura/picoruby-pavement"
```

During local development, use `conf.gem gemdir: "/path/to/picoruby-pavement"`.
The host runtime must provide Rack request handling and a `rack.input` stream.
The [demo-tape](https://github.com/udzura/demo-tape) Worker is an example.
For a complete project using this checkout, see
[`examples/hello-worker`](examples/hello-worker).

## Define an application

```ruby
class Application < Pavement::Base
  server_info name: "example", version: "1.0.0"

  tool "hello" do
    description "Greet a person"
    input { string :name, required: true }
    call { |name:| "Hello, #{name}!" }
  end

  tool "sum" do
    input do
      integer :left, required: true
      integer :right, required: true
    end
    output { integer :sum, required: true }
    call { |left:, right:| { sum: left + right } }
  end

  resource "demo://about" do
    name "About this server"
    mime_type "text/plain"
    read { about_text }
  end

  def about_text
    "Example MCP server"
  end
end
```

Tool `call` and resource `read` blocks run on a fresh application instance for
each request. Instance methods can access the current Rack hash through `env`.
Inputs support `string`, `integer`, and `boolean` with `required`, `default`,
and `description` options.

`output` is optional and uses the same field types. A tool with `output` must
return a Hash whose keys are strings or symbols. Pavement checks required and
unknown fields and their value types. It publishes the schema as `outputSchema`
and returns the normalized Hash as `structuredContent`, with JSON text in
`content` for clients that read text only. An invalid result becomes a tool
error. For 2025-03-26 clients, Pavement sends only the JSON text because that
revision has no structured output fields. Without `output`, the return value
is converted to text as before.

For tools that report progress, declare `enable :progress` and call the
`progress` helper from the tool block:

```ruby
tool "import" do
  enable :progress
  call do
    progress(1, total: 2, message: "Reading")
    progress(2, total: 2, message: "Done")
    "Imported"
  end
end
```

When the client supplies a `progressToken`, Pavement sends the notifications
and final tool result on one SSE response. Without a token, the helper does
nothing and the tool returns JSON as usual. Progress values must increase.
The helper works with both 2026-07-28 and supported legacy requests.

## Cancellation

For a long-running tool, declare `enable :cancellation` and check for a
disconnected client between steps:

```ruby
tool "import" do
  enable :cancellation
  call do
    check_cancelled!
    records = fetch_records
    check_cancelled!
    save_records(records)
    "Imported"
  ensure
    release_import_resources
  end
end
```

This feature uses an SSE response even without a `progressToken`, so the client
can cancel by closing the response stream. It requires the host's
`Cloudflare::CustomReadableStream` (Worker runtime 0.11.0 or later); without
that stream API, the tool uses JSON and cancellation checks do nothing.
`check_cancelled!` raises `Pavement::Cancelled` when the stream is unavailable.
Pavement stops the tool without sending a final result or an error on the lost
stream. Ruby `ensure` blocks still run. `cancelled?` returns a boolean if the
tool prefers to stop its loop explicitly.

Checks probe the response stream with an empty write, which sends no MCP
message. A failed stream write is treated as cancellation; repeated checks
remember it without retrying the stream. Checks use the stream's backpressure,
so a slow reader can delay them. Cancellation is cooperative: it does not
interrupt a running external call or a CPU loop that never checks. Place checks
before side effects and after external calls. A client disconnect also stops a
progress-enabled tool at its next failed progress write.

Combine `enable :cancellation, :progress` to report progress too. The progress
helper still requires a client-supplied `progressToken`. The supported legacy
HTTP requests use the same stream checks. This implementation handles response
stream disconnection; it does not track requests across connections or process
separate `notifications/cancelled` messages.

The app responds on `POST /mcp`. It uses the 2026-07-28 MCP protocol and accepts
legacy 2025-03-26, 2025-06-18, and 2025-11-25 Streamable HTTP handshakes. It
returns JSON responses unless a tool enables cancellation or reports progress.
Subscriptions are not implemented. By default,
only `localhost` and `127.0.0.1` Host headers are accepted. Set
`MCP_ALLOWED_HOSTS` to a comma-separated list for other hosts.

## Test

```sh
ruby test/pavement_env.rb
ruby test/pavement_progress.rb
```

GitHub Actions runs these tests and checks Ruby syntax on Ruby 4.0.

To test cancellation with the actual Wasm runtime, build the
[`hello-worker`](examples/hello-worker) example, then run from the repository root:

```sh
node test/pavement_cancellation.mjs
```

This test cancels response readers and aborts requests, verifies that later
work is skipped and cleanup runs, and checks successful completion on an open
stream. It uses local stand-ins for external HTTP services.
