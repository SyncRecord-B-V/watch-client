# frozen_string_literal: true

namespace :watch do
  desc 'Send a test log line to Watch and print the result'
  task test: :environment do
    exit(1) unless WatchClient.test!
  end

  desc "Send a test error to Watch's error tracking"
  task test_error: :environment do
    raise WatchClient::TestError,
          "Test error from #{WatchClient.configuration.app_name || 'app'} (bin/rails watch:test_error)"
  rescue WatchClient::TestError => e
    queued = WatchClient.notify(e, handled: true, context: { 'source' => 'watch:test_error' })
    WatchClient.flush(timeout: 10)
    sent = WatchClient.stats.dig(:errors, :sent).to_i
    if queued && sent.positive?
      puts 'OK: test error sent. Look for WatchClient::TestError under Errors in Watch.'
    else
      puts "FAILED: test error not sent (enabled: #{WatchClient.enabled?}, stats: #{WatchClient.stats.inspect})"
      exit(1)
    end
  end

  desc 'Record a deploy in Watch. Uses WATCH_APP_VERSION / HEROKU_SLUG_COMMIT / GIT_SHA, or VERSION=...'
  task deploy: :environment do
    config = WatchClient.configuration
    version = ENV['VERSION'].presence || config.app_version || `git rev-parse --short=12 HEAD 2>/dev/null`.strip.presence
    abort 'No version found: set VERSION=...' unless version

    ok = WatchClient.notify_deploy(version: version, revision: ENV['REVISION'],
                                   deployed_by: ENV['DEPLOYED_BY'] || ENV['USER'])
    puts ok ? "Deploy #{version} recorded in Watch." : 'Deploy not recorded (see message above).'
  end

  desc 'Heartbeat check-in: bin/rails watch:check_in TOKEN=... [FAIL=1] [MSG=...]'
  task check_in: :environment do
    token = ENV['TOKEN'].to_s
    abort 'Set TOKEN=<heartbeat token or ping URL>' if token.empty?

    ok = WatchClient::CheckIn.ping(WatchClient.configuration, token, failed: ENV['FAIL'].to_s == '1',
                                                                     message: ENV['MSG'])
    puts ok ? 'OK: check-in accepted.' : 'FAILED: check-in not accepted (see message above).'
    exit(1) unless ok
  end

  desc 'Database monitoring: print one sample (what the gem sends each minute); SEND=1 also sends it'
  task database: :environment do
    require 'json'
    config = WatchClient.configuration
    monitor = WatchClient::DatabaseMonitor.new(config)
    2.times { monitor.build_payload } # the second round has rates (they need two samples)
    sampler = monitor.sampler
    payload = monitor.build_payload
    payload['top_queries'] ||= sampler&.top_queries
    payload['tables'] ||= sampler&.tables
    puts JSON.pretty_generate(payload)
    if ENV['SEND'] == '1'
      ok = WatchClient::Transport.new(config, **WatchClient::Transport::DATABASE).post(payload).ok?
      puts ok ? 'Sent to Watch.' : 'Not sent (see message above).'
    end
  end

  desc 'Vulnerable gem check: print the gem list sent to Watch; SEND=1 also sends it'
  task dependencies: :environment do
    require 'json'
    body = WatchClient::Dependencies.payload
    abort 'No Gemfile.lock found.' unless body
    rails = body['rails'] ? ", Rails #{body['rails']}" : ''
    puts "#{body['gems'].size} gems, Ruby #{body['ruby']}#{rails} (digest #{body['digest'][0, 12]})"
    if ENV['SEND'] == '1'
      puts WatchClient::Dependencies.report! ? 'Sent to Watch.' : 'Not sent (see message above).'
    end
  end

  desc 'Show the Watch client configuration (without the API key)'
  task config: :environment do
    c = WatchClient.configuration
    puts "enabled:     #{c.enabled?}"
    puts "url:         #{c.url.inspect}"
    puts "api_key:     #{c.api_key ? "set (…#{c.api_key[-4..]})" : 'missing'}"
    puts "app_name:    #{c.app_name.inspect}"
    puts "environment: #{c.environment.inspect}"
    puts "host:        #{c.host.inspect}"
    puts "app_version: #{c.app_version.inspect}"
    puts "min_level:   #{c.min_level.inspect}"
  end
end
