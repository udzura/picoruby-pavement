# picoruby-pavement

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

The app responds on `POST /mcp`. It uses the 2026-07-28 MCP protocol and accepts
legacy 2025-03-26, 2025-06-18, and 2025-11-25 Streamable HTTP handshakes. It
returns JSON responses; SSE and subscriptions are not implemented. By default,
only `localhost` and `127.0.0.1` Host headers are accepted. Set
`MCP_ALLOWED_HOSTS` to a comma-separated list for other hosts.

## Test

```sh
ruby test/pavement_env.rb
```

GitHub Actions runs this test and checks Ruby syntax on Ruby 3.2 and 4.0.
