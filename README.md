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

The app responds on `POST /mcp`. It uses the 2026-07-28 MCP protocol and accepts
legacy 2025-03-26, 2025-06-18, and 2025-11-25 Streamable HTTP handshakes. It
returns JSON responses; SSE and subscriptions are not implemented. By default,
only `localhost` and `127.0.0.1` Host headers are accepted. Set
`MCP_ALLOWED_HOSTS` to a comma-separated list for other hosts.

## Test

```sh
ruby test/pavement_env.rb
```
