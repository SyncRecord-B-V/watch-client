require_relative "lib/watch_client/version"

Gem::Specification.new do |spec|
  spec.name = "watch_client"
  spec.version = WatchClient::VERSION
  spec.authors = [ "Ferdinand C" ]
  spec.email = [ "ferdinand.crayop@musqueteer.nl" ]

  spec.summary = "Connects a Rails app to Watch: logs, errors, performance, jobs, database and more."
  spec.description = "Sends logs, errors, deploys, performance, background job, process, database and dependency " \
                     "numbers to Watch (watch.syncrecord.com) in the background, without slowing the app down."
  spec.homepage = "https://github.com/SyncRecord-B-V/watch-client"
  spec.license = "Nonstandard"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["allowed_push_host"] = "https://example.invalid" # private gem: never push to rubygems.org
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = "https://github.com/SyncRecord-B-V/watch-client"
  spec.metadata["changelog_uri"] = "https://github.com/SyncRecord-B-V/watch-client/blob/main/CHANGELOG.md"

  spec.files = Dir["lib/**/*", "README.md", "CHANGELOG.md"]
  spec.require_paths = [ "lib" ]

  # Only Ruby's standard library ("logger" is a bundled gem from Ruby 3.5 on,
  # so it is declared). Rails integration loads when Rails is present (>= 7.1).
  spec.add_dependency "logger"
end
