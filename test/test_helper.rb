# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'minitest/autorun'
require 'socket'
require 'json'
require 'zlib'
require 'stringio'
require 'watch_client'

# A tiny HTTP/1.1 server on 127.0.0.1 that records requests and answers with
# queued status codes (default 202). Supports keep-alive like Log Hub.
class FakeHub
  Request = Struct.new(:method, :path, :headers, :body, keyword_init: true) do # rubocop:disable Lint/StructNewOverride
    def json
      raw = headers['content-encoding'] == 'gzip' ? Zlib.gunzip(body) : body
      JSON.parse(raw)
    end

    def entries
      json.fetch('entries', [])
    end

    def errors
      json.fetch('errors', [])
    end
  end

  attr_reader :requests

  def initialize
    @server = TCPServer.new('127.0.0.1', 0)
    @requests = Queue.new
    @statuses = Queue.new
    @threads = []
    @acceptor = Thread.new { accept_loop }
  end

  def url
    "http://127.0.0.1:#{@server.addr[1]}"
  end

  def respond_with(*codes)
    codes.each { |code| @statuses << code }
  end

  # Waits for the next request (or nil after timeout).
  def next_request(timeout: 3)
    deadline = Time.now + timeout
    loop do
      return @requests.pop(true)
    rescue ThreadError
      return nil if Time.now > deadline

      sleep 0.01
    end
  end

  def stop
    @acceptor.kill
    @threads.each(&:kill)
    @server.close
  rescue IOError
    nil
  end

  private

  def accept_loop
    loop do
      socket = @server.accept
      @threads << Thread.new(socket) { |s| serve(s) }
    end
  rescue IOError
    nil
  end

  def serve(socket)
    loop do
      line = socket.gets or break
      method, path, = line.split(' ')
      headers = {}
      while (header = socket.gets) && header != "\r\n"
        name, value = header.split(':', 2)
        headers[name.strip.downcase] = value.to_s.strip
      end
      body = socket.read(headers['content-length'].to_i)
      @requests << Request.new(method: method, path: path, headers: headers, body: body)

      code = begin
        @statuses.pop(true)
      rescue ThreadError
        202
      end
      reply = %({"accepted":1,"rejected":0})
      socket.write("HTTP/1.1 #{code} X\r\nContent-Type: application/json\r\nContent-Length: #{reply.bytesize}\r\n\r\n#{reply}")
    end
  rescue IOError, SystemCallError
    nil
  ensure
    begin
      socket.close
    rescue StandardError
      nil
    end
  end
end

module WatchTestHelpers
  def configure_for(hub, **overrides)
    WatchClient.reset!
    WatchClient.configure do |c|
      c.url = hub.url
      c.api_key = 'lh_test_key'
      c.app_name = 'test-app'
      c.environment = 'production'
      c.host = 'web-1'
      c.app_version = 'abc123'
      c.flush_interval = 0.05
      c.timeout = 2
      c.diagnostics = StringIO.new
      overrides.each { |key, value| c.public_send("#{key}=", value) }
    end
  end
end
