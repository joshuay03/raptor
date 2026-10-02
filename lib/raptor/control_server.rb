# rbs_inline: enabled
# frozen_string_literal: true

require "json"
require "socket"
require "uri"

require "atomic-ruby/atom"

module Raptor
  # Serves cluster statistics over a Unix socket.
  #
  class ControlServer
    SHUTDOWN = :shutdown

    # @rbs @path: String
    # @rbs @stats: ^() -> Hash[Symbol, untyped]
    # @rbs @server: UNIXServer?
    # @rbs @client: Atom
    # @rbs @thread: Thread?

    # Creates a control server for `url` without binding it.
    #
    # @param url [String] `unix://` URL to listen on
    # @yieldreturn [Hash] cluster statistics
    # @return [void]
    # @raise [ArgumentError] if the URL is not a Unix socket
    #
    # @rbs (String url) { () -> Hash[Symbol, untyped] } -> void
    def initialize(url, &stats)
      uri = URI(url)
      raise ArgumentError, "control_url must use unix://" unless uri.scheme == "unix" && !uri.path.empty?

      @path = uri.path
      @stats = stats
      @server = nil
      @client = Atom.new(nil)
      @thread = nil
    end

    # Binds the Unix socket.
    #
    # @return [void]
    #
    # @rbs () -> void
    def bind
      remove_stale_socket
      @server = UNIXServer.new(@path)
    end

    # Starts serving requests in a background thread.
    #
    # @return [void]
    #
    # @rbs () -> void
    def start
      owner_pid = Process.pid
      at_exit { File.delete(@path) rescue nil if Process.pid == owner_pid }

      @thread = Thread.new do
        Thread.current.name = "Control Server"

        serve
      end
    end

    # Stops serving and removes the socket.
    #
    # @return [void]
    #
    # @rbs () -> void
    def shutdown
      client = nil
      @client.swap do |current|
        client = current
        SHUTDOWN
      end
      @server&.close
      client.close if client.is_a?(UNIXSocket)
      @thread&.join
      File.delete(@path) rescue nil
    end

    private

    # Removes a stale socket while refusing to replace an active server.
    #
    # @return [void]
    # @raise [RuntimeError] if another server is listening on the socket
    #
    # @rbs () -> void
    def remove_stale_socket
      return unless File.exist?(@path)

      begin
        UNIXSocket.new(@path).close
        raise "Socket #{@path.inspect} is already in use"
      rescue Errno::ECONNREFUSED
        File.delete(@path)
      end
    end

    # Accepts and handles control requests until shutdown begins.
    #
    # @return [void]
    #
    # @rbs () -> void
    def serve
      until @client.value == SHUTDOWN
        readable, = IO.select([@server], nil, nil, 1)
        next unless readable

        client = @server.accept_nonblock(exception: false)
        next unless client.is_a?(UNIXSocket)

        if @client.swap { |current| current == SHUTDOWN ? current : client } == SHUTDOWN
          client.close
          return
        end

        handle(client)
      end
    rescue IOError, Errno::EBADF
    end

    # Writes the response for one control-socket request.
    #
    # @param client [UNIXSocket] connected control client
    # @return [void]
    #
    # @rbs (UNIXSocket client) -> void
    def handle(client)
      request_line = client.gets
      while line = client.gets
        break if line == "\r\n"
      end

      if request_line&.start_with?("GET /stats ")
        body = JSON.generate(@stats.call)
        client.write("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
      else
        client.write("HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n")
      end
    rescue IOError, SystemCallError
    ensure
      client.close rescue nil
      @client.swap { |current| current.equal?(client) ? nil : current }
    end
  end
end
