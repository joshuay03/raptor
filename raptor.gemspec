# frozen_string_literal: true

require_relative "lib/raptor/version"

Gem::Specification.new do |spec|
  spec.name = "raptor"
  spec.version = Raptor::VERSION
  spec.authors = ["Joshua Young"]
  spec.email = ["djry1999@gmail.com"]

  spec.summary = "A high-performance Ruby web server (rawr 🦖)"
  spec.homepage = "https://github.com/joshuay03/raptor"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) || f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/raptor_http/extconf.rb", "ext/raptor_http2/extconf.rb"]

  spec.add_dependency "rack", ">= 3.2.0"
  spec.add_dependency "nio4r"
  spec.add_dependency "atomic-ruby"
  spec.add_dependency "ractor-pool"
  spec.add_dependency "red-black-tree"
  spec.add_dependency "mmap-ruby"
  spec.add_dependency "libbpf-ruby"
end
