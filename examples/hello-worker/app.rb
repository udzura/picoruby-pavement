class Application < Pavement::Base
  server_info name: "pavement-hello-worker", version: "0.1.0"

  tool "hello" do
    description "Greet a person"
    input do
      string :name, required: true, description: "Name to greet"
      boolean :shout, default: false, description: "Use uppercase letters"
    end
    call do |name:, shout:|
      message = "Hello, #{name}!"
      shout ? message.upcase : message
    end
  end

  tool "sum" do
    description "Add two integers and return a structured result"
    input do
      integer :left, required: true
      integer :right, required: true
    end
    output { integer :sum, required: true }
    call { |left:, right:| { sum: left + right } }
  end

  resource "hello://about" do
    name "About hello-worker"
    description "Read about this server and the current request"
    mime_type "text/plain"
    read { about_text }
  end

  def about_text
    "A PicoRuby MCP server running on Cloudflare Workers. Host: #{env['HTTP_HOST']}"
  end
end

Rackup::Handler::CloudflareWorker.run(Application)
