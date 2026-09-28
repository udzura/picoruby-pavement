require "json"
require "stringio"
require_relative "../mrblib/pavement"

module Cloudflare
  class CustomReadableStream
    attr_reader :chunks

    def initialize(&block)
      @block = block
      @chunks = []
    end

    def on_error(&block)
      @on_error = block
    end

    def finish
      self
    end

    def run
      writer = Object.new
      chunks = @chunks
      writer.define_singleton_method(:write) { |chunk| chunks << chunk }
      @block.call(writer)
      @chunks
    end
  end
end

class ProgressApp < Pavement::Base
  tool "work" do
    enable :progress
    call do
      progress(1, total: 2, message: "First")
      progress(2, total: 2, message: "Done")
      "finished"
    end
  end

  tool "plain" do
    call { "plain result" }
  end
end

def call_tool(name, token = nil, legacy: false)
  meta = legacy ? {} : {
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => {}
  }
  meta["progressToken"] = token unless token.nil?
  env = {
    "PATH_INFO" => "/mcp", "REQUEST_METHOD" => "POST", "HTTP_HOST" => "localhost",
    "CONTENT_TYPE" => "application/json", "HTTP_MCP_PROTOCOL_VERSION" => legacy ? "2025-11-25" : "2026-07-28",
    "HTTP_MCP_METHOD" => "tools/call", "HTTP_MCP_NAME" => name,
    "rack.input" => StringIO.new(JSON.generate({ "jsonrpc" => "2.0", "id" => 7,
      "method" => "tools/call", "params" => { "name" => name, "arguments" => {}, "_meta" => meta } }))
  }
  status, headers, body = ProgressApp.call(env)
  [status, headers, body, env]
end

status, headers, body, env = call_tool("work", "job-1")
raise "stream response mismatch" unless status == 200 && headers["content-type"] == "text/event-stream" && body.empty?
events = env["cloudflare.hijack"].run.map { |chunk| JSON.parse(chunk.delete_prefix("data: ").strip) }
raise "wrong event count" unless events.length == 3
raise "wrong progress token" unless events[0]["params"]["progressToken"] == "job-1"
raise "progress order mismatch" unless events.first(2).map { |event| event["params"]["progress"] } == [1, 2]
raise "wrong final result" unless events.last["id"] == 7 && events.last["result"]["content"][0]["text"] == "finished"

status, headers, body, env = call_tool("work", 9, legacy: true)
raise "legacy stream response mismatch" unless status == 200 && headers["content-type"] == "text/event-stream" && body.empty?
events = env["cloudflare.hijack"].run.map { |chunk| JSON.parse(chunk.delete_prefix("data: ").strip) }
raise "legacy progress token mismatch" unless events[0]["params"]["progressToken"] == 9
raise "legacy final result mismatch" unless events.last["result"]["content"][0]["text"] == "finished" && !events.last["result"].key?("resultType")

status, headers, body, env = call_tool("work")
raise "missing-token fallback mismatch" unless status == 200 && headers["content-type"].start_with?("application/json") && !env.key?("cloudflare.hijack")
raise "missing-token result mismatch" unless JSON.parse(body.join)["result"]["content"][0]["text"] == "finished"

status, headers, body, env = call_tool("plain", "job-2")
raise "undeclared tool streamed" unless status == 200 && headers["content-type"].start_with?("application/json") && !env.key?("cloudflare.hijack")
raise "plain result mismatch" unless JSON.parse(body.join)["result"]["content"][0]["text"] == "plain result"

[[], [:unknown], ["progress"], [:progress, :unknown]].each do |features|
  tool = Pavement::Tool.new("validation") { call { "ok" } }
  begin
    tool.enable(*features)
    raise "invalid feature accepted: #{features.inspect}"
  rescue ArgumentError
    raise "invalid feature partially enabled" if tool.enabled?(:progress)
  end
end

puts "Pavement progress test passed"
