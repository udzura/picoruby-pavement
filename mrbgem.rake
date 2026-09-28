MRuby::Gem::Specification.new("picoruby-pavement") do |spec|
  spec.license = "MIT"
  spec.author = "Udzura"
  spec.summary = "Small MCP server DSL for PicoRuby"
  spec.add_dependency "mruby-jsonrs", github: "udzura/mruby-jsonrs"
end
