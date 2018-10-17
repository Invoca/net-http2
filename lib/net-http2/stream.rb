module NetHttp2

  class Stream

    def initialize(options={})
      @h2_stream = options[:h2_stream]
      @request   = options[:request]
      @async     = options[:async] || false
      @headers   = {}
      @data      = ''
      @completed = false
      @mutex     = Mutex.new
      @cv        = ConditionVariable.new

      listen_for_headers
      listen_for_data
      listen_for_close
    end

    def id
      @h2_stream.id
    end

    def call(body: nil, end_stream: true)
      data = body || @request.body

      if data
        send_headers(@request.headers, end_stream: false)
        send_data(data, end_stream: end_stream)
      else
        send_headers(@request.headers, end_stream: end_stream)
      end

      unless async?
        sync_respond
      end
    end

    def done
      send_data("", end_stream: true)
    end

    def completed?
      @completed
    end

    def async?
      @async
    end

    private

    def listen_for_headers
      @h2_stream.on(:headers) do |hs_array|
        hs = Hash[*hs_array.flatten]

        if async?
          @request.emit(:headers, hs)
        else
          @headers.merge!(hs)
        end
      end
    end

    def listen_for_data
      @h2_stream.on(:data) do |data|
        if async?
          @request.emit(:body_chunk, data)
        else
          @data << data
        end
      end
    end

    def listen_for_close
      @h2_stream.on(:close) do |data|
        @completed = true

        if async?
          @request.emit(:close, data)
        else
          @mutex.synchronize { @cv.signal }
        end
      end
    end

    def send_headers(headers, end_stream: false)
      unless @headers_sent
        @h2_stream.headers(headers, end_stream: end_stream)
        @headers_sent = true
      end
    end

    def send_data(data, end_stream: false)
      @h2_stream.data(data, end_stream: end_stream)
    end

    def sync_respond
      wait_for_completed

      NetHttp2::Response.new(headers: @headers, body: @data) if completed?
    end

    def wait_for_completed
      @mutex.synchronize { @cv.wait(@mutex, @request.timeout) }
    end
  end
end
