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

    def run(writer = nil)
      unless writer
        writer = Object.new
        chunks = @chunks
        writer.define_singleton_method(:write) { |chunk| chunks << chunk }
      end
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

def call_tool(name, token = nil, legacy: false, app: ProgressApp, extra_env: {})
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
  env.merge!(extra_env)
  status, headers, body = app.call(env)
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

class CancellationWriter
  attr_reader :chunks, :attempts

  def initialize
    @chunks = []
    @attempts = 0
  end

  def cancel!
    @cancelled = true
  end

  def write(chunk)
    @attempts += 1
    raise IOError, "reader disconnected" if @cancelled
    @chunks << chunk unless chunk.empty?
  end
end

class CancellationApp < Pavement::Base
  tool "checkpoint" do
    enable :cancellation
    call do
      env["test.context"] = self
      env["test.steps"] << "start"
      check_cancelled!
      env["test.writer"].cancel! if env["test.cancel"]
      check_cancelled!
      progress(1, message: "Not enabled for this tool")
      env["test.steps"] << "finished"
      "done"
    ensure
      env["test.steps"] << "cleanup"
      env["test.steps"] << "cancelled" if cancelled?
    end
  end

  tool "progress_cancel" do
    enable :progress
    call do
      progress(1, total: 2)
      env["test.writer"].cancel!
      progress(2, total: 2)
      env["test.steps"] << "finished"
      "done"
    ensure
      env["test.steps"] << "cleanup"
    end
  end

  tool "poll" do
    enable :cancellation
    call do
      env["test.writer"].cancel!
      raise "cancellation not detected" unless cancelled?
      raise "cancellation not remembered" unless cancelled?
      "done"
    end
  end

  tool "failed" do
    enable :cancellation
    call { raise "ordinary tool failure" }
  end
end

[false, true].each do |legacy|
  writer = CancellationWriter.new
  steps = []
  status, headers, body, env = call_tool("checkpoint", nil, legacy: legacy, app: CancellationApp,
    extra_env: { "test.writer" => writer, "test.steps" => steps, "test.cancel" => true })
  raise "cancellation needs a progress token" unless status == 200 && headers["content-type"] == "text/event-stream" && body.empty?
  env["cloudflare.hijack"].run(writer)
  raise "cancelled tool kept running" unless steps == ["start", "cleanup", "cancelled"]
  raise "cancelled tool sent a response" unless writer.chunks.empty?
  raise "cancelled stream was written again" unless writer.attempts == 2
  raise "cancellation context leaked" if env["test.context"].cancelled?

  writer = CancellationWriter.new
  steps = []
  # A token must not enable progress for a cancellation-only tool.
  _, _, _, env = call_tool("checkpoint", "unused-token", legacy: legacy, app: CancellationApp,
    extra_env: { "test.writer" => writer, "test.steps" => steps })
  env["cloudflare.hijack"].run(writer)
  raise "connected tool did not finish" unless steps == ["start", "finished", "cleanup"]
  raise "checkpoints sent protocol messages" unless writer.chunks.length == 1
  result = JSON.parse(writer.chunks[0].delete_prefix("data: "))["result"]
  raise "wrong completion result" unless result["content"][0]["text"] == "done" && !result["isError"]

  writer = CancellationWriter.new
  steps = []
  _, _, _, env = call_tool("progress_cancel", "job", legacy: legacy, app: CancellationApp,
    extra_env: { "test.writer" => writer, "test.steps" => steps })
  env["cloudflare.hijack"].run(writer)
  raise "failed progress write did not cancel" unless steps == ["cleanup"] && writer.chunks.length == 1 && writer.attempts == 2
end

writer = CancellationWriter.new
_, _, _, env = call_tool("poll", nil, app: CancellationApp, extra_env: { "test.writer" => writer })
env["cloudflare.hijack"].run(writer)
raise "polling retried a cancelled stream" unless writer.attempts == 1 && writer.chunks.empty?

writer = CancellationWriter.new
_, _, _, env = call_tool("failed", nil, app: CancellationApp)
env["cloudflare.hijack"].run(writer)
raise "ordinary failure treated as cancellation" unless JSON.parse(writer.chunks[0].delete_prefix("data: "))["result"]["isError"]

writer = CancellationWriter.new
writer.cancel!
# Failure to write a final result must also avoid an error-write retry.
_, _, _, env = call_tool("failed", nil, app: CancellationApp)
env["cloudflare.hijack"].run(writer)
raise "failed final write was retried" unless writer.attempts == 1 && writer.chunks.empty?

context = Pavement::Base.new({})
raise "JSON request marked cancelled" if context.cancelled?
raise "JSON cancellation check did not return normally" unless context.check_cancelled!.nil?

puts "Pavement progress test passed"
