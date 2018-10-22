require 'socket'
require 'openssl'
require 'uri'
require 'http/2'

module NetHttp2

  DRAFT               = 'h2'
  PROXY_SETTINGS_KEYS = [:proxy_addr, :proxy_port, :proxy_user, :proxy_pass]

  class Client

    include Callbacks

    attr_reader :uri

    def initialize(url, options={})
      @uri             = URI.parse(url)
      @connect_timeout = options[:connect_timeout] || 60
      @ssl_context     = add_npn_to_context(options[:ssl_context] || OpenSSL::SSL::SSLContext.new)

      PROXY_SETTINGS_KEYS.each do |key|
        instance_variable_set("@#{key}", options[key]) if options[key]
      end

      @is_ssl = (@uri.scheme == 'https')

      @mutex = Mutex.new
      init_vars
    end

    def call(method, path, options={})
      request = prepare_request(method, path, options)
      ensure_open
      new_stream(request: request).call
    end

    def call_async(request)
      stream = prepare_streaming(request)
      stream.call
    end

    def prepare_streaming(request)
      ensure_open
      new_monitored_stream_for(request)
    end

    def prepare_request(method, path, options={})
      NetHttp2::Request.new(method, @uri, path, options)
    end

    def ssl?
      @is_ssl
    end

    def close
      stop_socket_loop
      init_vars
    end

    def join
      while !@streams.empty? do
        EMP.sleep 0.05
      end
    end

    def remote_settings
      h2.remote_settings
    end

    def stream_count
      @streams.length
    end

    private

    def init_vars
      @mutex.synchronize do
        @socket.close if @socket && !@socket.closed?

        @h2              = nil
        @socket          = nil
        @socket_thread   = nil
        @first_data_sent = false
        @streams         = {}
      end
    end

    def new_stream(request:, async: false)
      NetHttp2::Stream.new(h2_stream: h2.new_stream, request: request, async: async)
    rescue StandardError => e
      close
      raise e
    end

    def new_monitored_stream_for(request)
      stream = new_stream(request: request, async: true)

      @streams[stream.id] = true
      request.on(:close) { @streams.delete(stream.id) }

      stream
    end

    def ensure_open
      @mutex.synchronize do

        return if @socket_loop

        @socket = new_socket

        @socket_loop = start_socket_loop
      end
    end

    def callback_or_raise(exception)
      if callback_events.keys.include?(:error)
        emit(:error, exception)
      else
        raise exception
      end
    end

    def start_socket_loop
      EMP.add_periodic_timer(0.01) do
        begin
          socket_loop

        rescue EOFError
          # socket closed
          init_vars
          callback_or_raise SocketError.new('Socket was remotely closed')

        rescue Exception => e
          # error on socket
          init_vars
          callback_or_raise e
        end
      end
    end

    def stop_socket_loop
      if @socket_loop
        @socket_loop.cancel
        @socket_loop = nil
      end
    end

    def socket_loop
      if @first_data_sent
        begin
          data_received = @socket.read_nonblock(1024)
          h2 << data_received
        rescue IO::WaitReadable, IO::WaitWritable
        end
      end
    end

    def new_socket
      options = {
        ssl: ssl?, ssl_context: @ssl_context, connect_timeout: @connect_timeout
      }
      PROXY_SETTINGS_KEYS.each { |k| options[k] = instance_variable_get("@#{k}") }
      NetHttp2::Socket.create(@uri, options)
    end

    def ensure_sent_before_receiving
      while !@first_data_sent
        EMP.sleep 0.01
      end
    end

    def h2
      @h2 ||= HTTP2::Client.new.tap do |h2|
        h2.on(:frame) do |bytes|
          @mutex.synchronize do
            @socket.write(bytes)
            @socket.flush

            @first_data_sent = true
          end
        end
      end
    end

    def add_npn_to_context(ctx)
      ctx.npn_protocols = [DRAFT]
      ctx.npn_select_cb = lambda do |protocols|
        DRAFT if protocols.include?(DRAFT)
      end
      ctx
    end

    def exit_thread(thread)
      return unless thread
      thread.exit
      thread.join
    end
  end
end
