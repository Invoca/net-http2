require 'spec_helper'

describe NetHttp2::Stream do
  let(:h2_client) { HTTP2::Client.new }
  let(:h2_stream) { h2_client.new_stream }

  let(:method) { :post }
  let(:uri) { URI.parse("http://localhost") }
  let(:path) { "/path" }
  let(:params) { nil }
  let(:body) { "request body" }
  let(:headers) { {} }
  let(:timeout) { nil }
  let(:request) do
    @chunks = []
    r = NetHttp2::Request.new(method, uri, path, params: params, headers: headers, body: body, timeout: timeout)
    r.on(:headers) { |headers| @headers = headers }
    r.on(:body_chunk) { |data| @chunks << data }
    r.on(:close) { |_| @closed = true }
    r
  end

  let(:async) { true }
  let(:stream) { NetHttp2::Stream.new(h2_stream: h2_stream, request: request, async: async) }

  shared_examples_for "sending request data" do
    context "when request body is specified" do
      it "sends both header and body request to h2_stream" do
        expect(h2_stream).to receive(:headers).with(headers, end_stream: false)
        expect(h2_stream).to receive(:data).with(body, end_stream: true)
        stream.call
      end
    end

    context "when request body is not specified" do
      let(:body) { nil }

      it "sends only a header request" do
        expect(h2_stream).to receive(:headers).with(headers, end_stream: true)
        expect(h2_stream).to_not receive(:data)
        stream.call
      end
    end
  end

  shared_examples_for "synchronous requests" do
    let(:mock_wait) { true }

    before { (expect(stream).to receive(:wait_for_completed)) if mock_wait }

    context "when completed" do
      let(:mock_wait) { false }

      it "responds with response when completed" do
        expect(stream).to receive(:wait_for_completed).and_wrap_original do |m, *args|
          h2_stream.emit(:close, nil)
        end
        expect(stream.call).to be_instance_of(NetHttp2::Response)
      end
    end

    context "when not completed" do
      it "responds with nil when not completed" do
        expect(stream.call).to be_nil
      end
    end
  end

  describe "#id" do
    subject { stream.id }

    it { is_expected.to equal(h2_stream.id) }
  end

  describe "#call" do
    context "async is true" do
      include_examples "sending request data"

      it "is idempotent in sending headers" do
        expect(h2_stream).to receive(:headers).with(headers, end_stream: false)
        expect(h2_stream).to receive(:data).with(body, end_stream: false)
        expect(h2_stream).to receive(:data).with(body, end_stream: true)

        stream.call(end_stream: false)
        stream.call(end_stream: true)
      end
    end

    context "async is false" do
      let(:async) { false }
      it_behaves_like "synchronous requests" do
        include_examples "sending request data"
      end
    end

    context "async is not provided" do
      let(:async) { nil }
      it_behaves_like "synchronous requests" do
        include_examples "sending request data"
      end
    end

    context "body is provided by param" do
      it "takes precedence over request body" do
        param_body = "param body"
        expect(h2_stream).to receive(:headers).with(headers, end_stream: false)
        expect(h2_stream).to receive(:data).with(param_body, end_stream: true)
        stream.call(body: param_body)
      end
    end
  end

  describe "#done" do
    it "sends empty data with end_stream as true" do
      expect(h2_stream).to receive(:data).with("", end_stream: true)
      stream.done
    end
  end
end
