require "json"
require "stringio"
require_relative "../mrblib/pavement"

class EnvTestApp < Pavement::Base
  server_info name: "env-test", version: "1.0.0"

  tool "inspect" do
    input { string :name, required: true }
    call { |name:| marker_for(name) }
  end

  tool "sum" do
    input do
      integer :left, required: true
      integer :right, required: true
    end
    output do
      integer :sum, required: true
    end
    call { |left:, right:| { sum: left + right } }
  end

  tool "invalid_output" do
    output { integer :count, required: true }
    call { { count: "not an integer" } }
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
  legacy_version = legacy == true ? "2025-11-25" : legacy
  params = params.merge("_meta" => {
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => {}
  }) unless legacy
  env = {
    "PATH_INFO" => "/mcp",
    "REQUEST_METHOD" => "POST",
    "HTTP_HOST" => "localhost",
    "CONTENT_TYPE" => "application/json",
    "HTTP_MCP_PROTOCOL_VERSION" => legacy_version || "2026-07-28",
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

tools = request("tools/list", {}, "tools")["tools"]
sum_tool = tools.find { |tool| tool["name"] == "sum" }
raise "output schema mismatch" unless sum_tool["outputSchema"] == {
  "type" => "object", "properties" => { "sum" => { "type" => "integer" } },
  "additionalProperties" => false, "required" => ["sum"]
}
raise "text tool has output schema" if tools.find { |tool| tool["name"] == "inspect" }.key?("outputSchema")

sum = request("tools/call", { "name" => "sum", "arguments" => { "left" => 2, "right" => 3 } }, "sum")
raise "structured output mismatch" unless sum["structuredContent"] == { "sum" => 5 } &&
  JSON.parse(sum["content"][0]["text"]) == { "sum" => 5 } && !sum["isError"]

legacy_sum = request("tools/call", { "name" => "sum", "arguments" => { "left" => 1, "right" => 2 } }, "sum", legacy: true)
raise "legacy structured output mismatch" unless legacy_sum["structuredContent"] == { "sum" => 3 }

old_tools = request("tools/list", {}, "tools", legacy: "2025-03-26")["tools"]
raise "old client received output schema" if old_tools.any? { |tool| tool.key?("outputSchema") }
old_sum = request("tools/call", { "name" => "sum", "arguments" => { "left" => 1, "right" => 2 } }, "sum", legacy: "2025-03-26")
raise "old client received structured output" if old_sum.key?("structuredContent")
raise "old client lost JSON text" unless JSON.parse(old_sum["content"][0]["text"]) == { "sum" => 3 }

invalid = request("tools/call", { "name" => "invalid_output" }, "invalid")
raise "invalid output accepted" unless invalid["isError"] && !invalid.key?("structuredContent")

schema = Pavement::Schema.new
schema.integer :count, required: true
[{ "count" => "1" }, {}, { "count" => 1, "extra" => true }, [1], { count: 1, "count" => 2 }].each do |value|
  begin
    schema.validate_output(value)
    raise "invalid output accepted: #{value.inspect}"
  rescue Pavement::InvalidOutput
  end
end

puts "Pavement env test passed"
