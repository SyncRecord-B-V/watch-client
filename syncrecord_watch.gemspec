require_relative "lib/syncrecord_watch/version"

Gem::Specification.new do |spec|
  spec.name = "syncrecord_watch"
  spec.version = SyncRecordWatch::VERSION
  spec.authors = [ "Ferdinand C" ]
  spec.email = [ "ferdinand.crayop@musqueteer.nl" ]

  spec.summary = "Connects a Rails app to Sync Record Watch: logs, errors, performance, jobs, database and more."
  spec.description = "Sends logs, errors, deploys, performance, background job, process, database and dependency " \
                     "numbers to Sync Record Watch (watch.syncrecord.com) in the background, without slowing the app down."
  spec.license = "Nonstandard"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["allowed_push_host"] = "https://example.invalid" # private gem: never push to rubygems.org
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*", "README.md", "CHANGELOG.md"]
  spec.require_paths = [ "lib" ]

  # Only Ruby's standard library ("logger" is a bundled gem from Ruby 3.5 on,
  # so it is declared). Rails integration loads when Rails is present (>= 7.1).
  spec.add_dependency "logger"
end
