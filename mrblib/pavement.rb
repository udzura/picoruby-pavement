module Pavement
  PROTOCOL_VERSION = "2026-07-28"
  LEGACY_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26"]

  class InvalidInput < StandardError; end
  class InvalidOutput < StandardError; end

  class Schema
    def initialize
      @fields = {}
    end

    def string(name, required: false, default: nil, description: nil)
      field(name, "string", required, default, description)
    end

    def integer(name, required: false, default: nil, description: nil)
      field(name, "integer", required, default, description)
    end

    def boolean(name, required: false, default: nil, description: nil)
      field(name, "boolean", required, default, description)
    end

    def field(name, type, required, default, description)
      key = name.to_s
      raise ArgumentError, "duplicate input: #{key}" if @fields.key?(key)
      @fields[key] = { "type" => type, "required" => required, "default" => default, "description" => description }
    end

    def json_schema
      properties = {}
      required = []
      @fields.each do |name, field|
        property = { "type" => field["type"] }
        property["description"] = field["description"] if field["description"]
        property["default"] = field["default"] unless field["default"].nil?
        properties[name] = property
        required << name if field["required"]
      end
      schema = { "type" => "object", "properties" => properties, "additionalProperties" => false }
      schema["required"] = required unless required.empty?
      schema
    end

    def prepare(arguments)
      raise InvalidInput, "arguments must be an object" unless arguments.is_a?(Hash)
      arguments.each_key do |name|
        raise InvalidInput, "unknown argument: #{name}" unless @fields.key?(name)
      end
      values = {}
      @fields.each do |name, field|
        value = arguments[name]
        if value.nil?
          value = field["default"]
          raise InvalidInput, "missing argument: #{name}" if value.nil? && field["required"]
          next if value.nil?
        end
        valid = case field["type"]
                when "string" then value.is_a?(String)
                when "integer" then value.is_a?(Integer)
                when "boolean" then value == true || value == false
                end
        raise InvalidInput, "#{name} must be #{field['type']}" unless valid
        values[name.to_sym] = value
      end
      values
    end

    def validate_output(value)
      raise InvalidOutput, "output must be an object" unless value.is_a?(Hash)
      normalized = {}
      value.each do |key, item|
        raise InvalidOutput, "output keys must be strings or symbols" unless key.is_a?(String) || key.is_a?(Symbol)
        name = key.to_s
        raise InvalidOutput, "unknown output: #{name}" unless @fields.key?(name)
        raise InvalidOutput, "duplicate output: #{name}" if normalized.key?(name)
        normalized[name] = item
      end
      @fields.each do |name, field|
        unless normalized.key?(name)
          raise InvalidOutput, "missing output: #{name}" if field["required"]
          next
        end
        item = normalized[name]
        valid = case field["type"]
                when "string" then item.is_a?(String)
                when "integer" then item.is_a?(Integer)
                when "boolean" then item == true || item == false
                end
        raise InvalidOutput, "#{name} must be #{field['type']}" unless valid
      end
      normalized
    end
  end

  class Tool
    SUPPORTED_FEATURES = [:progress].freeze

    attr_reader :name

    def initialize(name, &block)
      @name = name
      @schema = Schema.new
      instance_eval(&block)
      raise ArgumentError, "tool #{name} needs a call block" unless @handler
    end

    def description(value)
      @description = value
    end

    def input(&block)
      @schema.instance_eval(&block)
    end

    def output(&block)
      raise ArgumentError, "duplicate output declaration for #{@name}" if @output_schema
      @output_schema = Schema.new
      @output_schema.instance_eval(&block)
    end

    def call(&block)
      @handler = block
    end

    def enable(*features)
      raise ArgumentError, "enable needs at least one feature" if features.empty?
      features.each do |feature|
        raise ArgumentError, "unsupported tool feature: #{feature.inspect}" unless SUPPORTED_FEATURES.include?(feature)
      end
      @enabled_features ||= {}
      features.each { |feature| @enabled_features[feature] = true }
    end

    def enabled?(feature)
      @enabled_features.is_a?(Hash) && @enabled_features[feature] == true
    end

    def definition
      result = { "name" => @name, "inputSchema" => @schema.json_schema }
      result["description"] = @description if @description
      result["outputSchema"] = @output_schema.json_schema if @output_schema
      result
    end

    def structured_output?
      !@output_schema.nil?
    end

    def validate_output(value)
      @output_schema.validate_output(value)
    end

    def invoke(arguments, context)
      context.instance_exec(**@schema.prepare(arguments), &@handler)
    end
  end

  class Resource
    attr_reader :uri

    def initialize(uri, &block)
      @uri = uri
      instance_eval(&block)
      raise ArgumentError, "resource #{uri} needs a read block" unless @reader
    end

    def name(value)
      @name = value
    end

    def description(value)
      @description = value
    end

    def mime_type(value)
      @mime_type = value
    end

    def read(&block)
      @reader = block
    end

    def definition
      result = { "uri" => @uri, "name" => @name || @uri }
      result["description"] = @description if @description
      result["mimeType"] = @mime_type if @mime_type
      result
    end

    def contents(context)
      { "uri" => @uri, "mimeType" => @mime_type || "text/plain", "text" => context.instance_exec(&@reader).to_s }
    end
  end

  class Application
    def initialize(&block)
      @tools = {}
      @resources = {}
      @server_info = { "name" => "pavement", "version" => "0.1.0" }
      instance_eval(&block) if block
    end

    def server_info(name:, version:)
      @server_info = { "name" => name, "version" => version }
    end

    def tool(name, &block)
      raise ArgumentError, "duplicate tool: #{name}" if @tools.key?(name)
      @tools[name] = Tool.new(name, &block)
    end

    def resource(uri, &block)
      raise ArgumentError, "duplicate resource: #{uri}" if @resources.key?(uri)
      @resources[uri] = Resource.new(uri, &block)
    end

    def call(env, context = Base.new(env))
      return response(404, { "error" => "Not found" }) unless env["PATH_INFO"] == "/mcp"
      return [405, { "allow" => "POST" }, []] unless env["REQUEST_METHOD"] == "POST"
      allowed_hosts = (ENV["MCP_ALLOWED_HOSTS"] || "localhost,127.0.0.1").split(",")
      host = env["HTTP_HOST"].to_s.split(":").first
      return response(403, { "error" => "Forbidden host" }) unless allowed_hosts.include?(host)
      origin = env["HTTP_ORIGIN"]
      if origin
        origin_host = origin[/\Ahttps?:\/\/([^\/]+)\z/, 1]
        return response(403, { "error" => "Forbidden origin" }) unless origin_host == env["HTTP_HOST"]
      end
      return response(415, { "error" => "Content-Type must be application/json" }) unless env["CONTENT_TYPE"].to_s.split(";").first.to_s.downcase == "application/json"

      request = JSON.parse(env["rack.input"].read)
      if request.is_a?(Hash) && request["jsonrpc"] == "2.0" && request["method"] == "notifications/initialized" && !request.key?("id")
        return [202, {}, []]
      end
      valid_id = request.is_a?(Hash) && (request["id"].is_a?(String) || request["id"].is_a?(Numeric))
      return rpc_error(400, nil, -32600, "Invalid Request") unless valid_id && request["jsonrpc"] == "2.0" && request["method"].is_a?(String)
      id = request["id"]
      method = request["method"]
      params = request["params"] || {}
      return rpc_error(400, id, -32602, "params must be an object") unless params.is_a?(Hash)
      if method == "initialize" && !modern_metadata?(params)
        return legacy_initialize(id, params)
      end
      if !modern_metadata?(params) && env["HTTP_MCP_PROTOCOL_VERSION"] != PROTOCOL_VERSION
        return legacy_request(id, method, params, env["HTTP_MCP_PROTOCOL_VERSION"], context)
      end
      meta = params["_meta"]
      return rpc_error(400, id, -32602, "Missing request metadata") unless meta.is_a?(Hash) && meta["io.modelcontextprotocol/clientCapabilities"].is_a?(Hash) && meta["io.modelcontextprotocol/protocolVersion"].is_a?(String)

      version = meta["io.modelcontextprotocol/protocolVersion"]
      name = case method
             when "tools/call" then params["name"]
             when "resources/read" then params["uri"]
             end
      needs_name = method == "tools/call" || method == "resources/read"
      unless env["HTTP_MCP_PROTOCOL_VERSION"] == version && env["HTTP_MCP_METHOD"] == method && (!needs_name || (name.is_a?(String) && header_value(env["HTTP_MCP_NAME"]) == name))
        return rpc_error(400, id, -32020, "MCP headers do not match request body")
      end
      unless version == PROTOCOL_VERSION
        return rpc_error(400, id, -32022, "Unsupported protocol version", { "supported" => [PROTOCOL_VERSION], "requested" => version })
      end
      return rpc_error(400, id, -32602, "name or uri is required") if (method == "tools/call" || method == "resources/read") && !name.is_a?(String)

      tool = @tools[name] if method == "tools/call"
      if tool && tool.enabled?(:progress) && progress_token?(meta["progressToken"]) && defined?(Cloudflare::CustomReadableStream)
        return stream_tool_call(env, id, params, context, meta["progressToken"])
      end

      result = dispatch(method, params, context)
      return rpc_error(404, id, -32601, "Method not found") if result == :method_not_found
      return rpc_error(400, id, -32602, "Unknown tool or resource") if result == :not_found
      response(200, { "jsonrpc" => "2.0", "id" => id, "result" => result })
    rescue JSON::ParserError
      rpc_error(400, nil, -32700, "Parse error")
    rescue InvalidInput => e
      rpc_error(400, id, -32602, e.message)
    rescue => e
      rpc_error(500, id, -32603, "Internal error")
    end

    def dispatch(method, params, context)
      result = case method
               when "server/discover"
                 { "supportedVersions" => [PROTOCOL_VERSION], "capabilities" => capabilities }
               when "tools/list"
                 { "tools" => @tools.keys.sort.map { |name| @tools[name].definition }, "ttlMs" => 60_000, "cacheScope" => "public" }
               when "tools/call"
                 tool = @tools[params["name"]]
                 return :not_found unless tool
                 begin
                   value = tool.invoke(params["arguments"] || {}, context)
                   if tool.structured_output?
                     structured = tool.validate_output(value)
                     { "content" => [{ "type" => "text", "text" => JSON.generate(structured) }], "structuredContent" => structured, "isError" => false }
                   else
                     { "content" => [{ "type" => "text", "text" => value.to_s }], "isError" => false }
                   end
                 rescue InvalidInput
                   raise
                 rescue InvalidOutput
                   { "content" => [{ "type" => "text", "text" => "Tool output did not match its schema" }], "isError" => true }
                 rescue => e
                   { "content" => [{ "type" => "text", "text" => "Tool execution failed" }], "isError" => true }
                 end
               when "resources/list"
                 { "resources" => @resources.keys.sort.map { |uri| @resources[uri].definition }, "ttlMs" => 60_000, "cacheScope" => "public" }
               when "resources/templates/list"
                 { "resourceTemplates" => [], "ttlMs" => 60_000, "cacheScope" => "public" }
               when "resources/read"
                 resource = @resources[params["uri"]]
                 return :not_found unless resource
                 { "contents" => [resource.contents(context)] }
               else
                 return :method_not_found
               end
      result["resultType"] = "complete"
      result["_meta"] = { "io.modelcontextprotocol/serverInfo" => @server_info }
      result
    end

    def capabilities
      { "tools" => {}, "resources" => {} }
    end

    def progress_token?(value)
      value.is_a?(String) || value.is_a?(Integer)
    end

    def stream_tool_call(env, id, params, context, token, legacy_version = nil)
      stream = Cloudflare::CustomReadableStream.new do |writer|
        context.__with_progress(writer, token) do
          message = begin
            result = dispatch("tools/call", params, context)
            result = legacy_result("tools/call", result, legacy_version) if legacy_version
            { "jsonrpc" => "2.0", "id" => id, "result" => result }
          rescue InvalidInput => e
            { "jsonrpc" => "2.0", "id" => id, "error" => { "code" => -32602, "message" => e.message } }
          rescue
            { "jsonrpc" => "2.0", "id" => id, "error" => { "code" => -32603, "message" => "Internal error" } }
          end
          writer.write(sse_message(message))
        end
      end
      stream.on_error { "data: #{JSON.generate({ "jsonrpc" => "2.0", "id" => id, "error" => { "code" => -32603, "message" => "Internal error" } })}\n\n" }
      env["cloudflare.hijack"] = stream.finish
      [200, { "content-type" => "text/event-stream", "cache-control" => "no-store", "x-accel-buffering" => "no" }, []]
    end

    def sse_message(message)
      "data: #{JSON.generate(message)}\n\n"
    end

    def modern_metadata?(params)
      meta = params["_meta"]
      meta.is_a?(Hash) && meta.key?("io.modelcontextprotocol/protocolVersion")
    end

    def legacy_initialize(id, params)
      return rpc_error(400, id, -32602, "Invalid initialize params") unless params["protocolVersion"].is_a?(String) && params["capabilities"].is_a?(Hash) && params["clientInfo"].is_a?(Hash)
      version = LEGACY_VERSIONS.include?(params["protocolVersion"]) ? params["protocolVersion"] : LEGACY_VERSIONS.first
      result = { "protocolVersion" => version, "capabilities" => capabilities, "serverInfo" => @server_info }
      response(200, { "jsonrpc" => "2.0", "id" => id, "result" => result })
    end

    def legacy_request(id, method, params, version, context)
      version ||= LEGACY_VERSIONS.last
      return rpc_error(400, id, -32602, "Unsupported legacy protocol version") unless LEGACY_VERSIONS.include?(version)
      tool = @tools[params["name"]] if method == "tools/call"
      token = params["_meta"].is_a?(Hash) && params["_meta"]["progressToken"]
      if tool && tool.enabled?(:progress) && progress_token?(token) && defined?(Cloudflare::CustomReadableStream)
        return stream_tool_call(context.env, id, params, context, token, version)
      end
      result = method == "ping" ? {} : dispatch(method, params, context)
      return rpc_error(404, id, -32601, "Method not found") if result == :method_not_found
      return rpc_error(400, id, -32602, "Unknown tool or resource") if result == :not_found
      result = legacy_result(method, result, version)
      response(200, { "jsonrpc" => "2.0", "id" => id, "result" => result })
    end

    def legacy_result(method, result, version)
      if version == "2025-03-26"
        result["tools"].each { |tool| tool.delete("outputSchema") } if method == "tools/list"
        result.delete("structuredContent") if method == "tools/call"
      end
      result.delete("resultType")
      result.delete("_meta")
      result.delete("ttlMs")
      result.delete("cacheScope")
      result
    end

    def header_value(value)
      return nil unless value.is_a?(String)
      if value.start_with?("=?base64?") && value.end_with?("?=")
        value[9...-2].unpack("m").first
      else
        value
      end
    end

    def rpc_error(status, id, code, message, data = nil)
      error = { "code" => code, "message" => message }
      error["data"] = data if data
      response(status, { "jsonrpc" => "2.0", "id" => id, "error" => error })
    end

    def response(status, body)
      [status, { "content-type" => "application/json; charset=utf-8", "cache-control" => "no-store" }, [JSON.generate(body)]]
    end
  end

  class Base
    attr_reader :env

    def initialize(env)
      @env = env
    end

    def call
      self.class.application.call(env, self)
    end

    def progress(value, total: nil, message: nil)
      return false unless @progress_writer
      raise ArgumentError, "progress must increase" unless value.is_a?(Numeric) && (@last_progress.nil? || value > @last_progress)
      raise ArgumentError, "total must be numeric" unless total.nil? || total.is_a?(Numeric)
      raise ArgumentError, "message must be a String" unless message.nil? || message.is_a?(String)
      params = { "progressToken" => @progress_token, "progress" => value }
      params["total"] = total unless total.nil?
      params["message"] = message unless message.nil?
      @progress_writer.write("data: #{JSON.generate({ "jsonrpc" => "2.0", "method" => "notifications/progress", "params" => params })}\n\n")
      @last_progress = value
      true
    end

    def __with_progress(writer, token)
      @progress_writer = writer
      @progress_token = token
      @last_progress = nil
      yield
    ensure
      @progress_writer = @progress_token = @last_progress = nil
    end

    def self.tool(name, &block)
      application.tool(name, &block)
    end

    def self.server_info(name:, version:)
      application.server_info(name: name, version: version)
    end

    def self.resource(uri, &block)
      application.resource(uri, &block)
    end

    def self.call(env)
      new(env).call
    end

    def self.application
      @application ||= Application.new
    end
  end
end
