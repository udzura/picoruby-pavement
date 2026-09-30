require "picoruby/cloudflare/build"

ENV["PICORUBY_USE_MRUBY_JSONRS"] = "1"

MRuby::CrossBuild.new("worker") do |conf|
  conf.cloudflare_worker! do |cf|
    cf.picoruby_cloudflare_worker_wasm_revision = "0.11.0"
  end

  conf.gem gemdir: File.expand_path("../..", __dir__)

  conf.worker_export(
    app: "app.rb",
    output_dir: "generated/worker",
    wrangler_config: "wrangler.jsonc",
    project_root: __dir__,
  )
end
