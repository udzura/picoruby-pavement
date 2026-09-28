require "json"
require "stringio"
require_relative "../mrblib/pavement"

class EnvTestApp < Pavement::Base
  server_info name: "env-test", version: "1.0.0"

  tool "inspect" do
    input { string :name, required: true }
    call { |name:| marker_for(name) }
  end

  resource "demo://request" do
    read { marker_for("resource") }
  end

  def marker_for(name)
    @calls = (@calls || 0) + 1
    "#{name}:#{env['HTTP_X_TEST']}:#{self.class}:#{@calls}"
  end
end

def request(method, params, marker, legacy: false)
  params = params.merge("_meta" => {
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => {}
  }) unless legacy
  env = {
    "PATH_INFO" => "/mcp",
    "REQUEST_METHOD" => "POST",
    "HTTP_HOST" => "localhost",
    "CONTENT_TYPE" => "application/json",
    "HTTP_MCP_PROTOCOL_VERSION" => legacy ? "2025-11-25" : "2026-07-28",
    "HTTP_MCP_METHOD" => method,
    "HTTP_MCP_NAME" => params["name"] || params["uri"],
    "HTTP_X_TEST" => marker,
    "rack.input" => StringIO.new(JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params }))
  }
  status, _, body = EnvTestApp.call(env)
  raise "HTTP #{status}: #{body.join}" unless status == 200
  JSON.parse(body.join)["result"]
end

first = request("tools/call", { "name" => "inspect", "arguments" => { "name" => "one" } }, "first")
raise "tool context mismatch" unless first["content"][0]["text"] == "one:first:EnvTestApp:1"
raise "server info mismatch" unless first["_meta"]["io.modelcontextprotocol/serverInfo"] == { "name" => "env-test", "version" => "1.0.0" }

second = request("tools/call", { "name" => "inspect", "arguments" => { "name" => "two" } }, "second", legacy: true)
raise "tool context leaked" unless second["content"][0]["text"] == "two:second:EnvTestApp:1"

resource = request("resources/read", { "uri" => "demo://request" }, "resource")
raise "resource context mismatch" unless resource["contents"][0]["text"] == "resource:resource:EnvTestApp:1"

puts "Pavement env test passed"
