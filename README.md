# Hermes

Hermes - a messenger of gods, delivering them via RabbitMQ with a little help from [hutch](https://github.com/gocardless/hutch).

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'hermes-rb'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install hermes-rb

## Usage

First, define an initializer, for example `config/initializers/hermes.rb`

``` rb
Rails.application.config.to_prepare do
  event_handler = Hermes::EventHandler.new

  Hermes.configure do |config|
    config.adapter = Rails.application.config.async_messaging_adapter
    config.application_prefix = "my_app"
    config.background_processor = HermesHandlerJob
    config.enqueue_method = :perform_async
    config.event_handler = event_handler
    config.clock = Time.zone
    config.instrumenter = Instrumenter
    config.configure_hutch do |hutch|
      hutch.uri = ENV.fetch("HUTCH_URI")
    end
    config.distributed_tracing_database_uri = ENV.fetch("DISTRIBUTED_TRACING_DATABASE_URI")
  end

  event_handler.handle_events do
    handle Events::Example::Happened, with: Example::HappenedHandler

    handle Events::Example::SyncCallHappened, with: Example::SyncCallHappenedHandler, async: false
  end

  # if you care about distributed tracing
  Hermes::DistributedTrace.establish_connection(Hermes.configuration.distributed_tracing_database_uri)
end

Hutch::Logging.logger = Rails.logger if !Rails.env.test? && !Rails.env.development?
```

Note that not all options are required (could be the case if the application is just a producer or just a consumer).

1. `adapter` - messages can be either delivered via RabbitMQ or in-memory adapter (useful for testing). Most likely you will want to make it based on the environment, that's why it's advisable to use `Rails.application.config.async_messaging_adapter` and define `async_messaging_adapter` on `config` object in `development.rb`, `test.rb` and `production.rb` files. The recommended setup is to assign `config.async_messaging_adapter = :in_memory` for test ENV and `config.async_messaging_adapter = :hutch` for production and development ENVs.
2. `application_prefix` - identifier for this application. **ABSOLUTELY NECESSARY** unless you want to have competing queues with different applications (hint: most likely you don't want that).

3 and 4. `background_processor` and `enqueue_method`. By design, Hermes is supposed to use Hutch workers to fetch the messages from RabbitMQ and process them in some background jobs framework. `background_processor` refers to the name of the class for the job and `enqueue_method` is the method name that will be called when enqueuing the job. This method must accept three arguments: `event_class`, `body` and `headers`. Here is an example for Sidekiq:

``` rb
class HermesHandlerJob
  include Sidekiq::Worker

  sidekiq_options queue: :critical

  def perform(event_class, body, headers)
    Hermes::EventProcessor.call(event_class, body, headers)
  end
end
```

If you know what you are doing, you don't necessarily have to process things in the background. As long as the class implements the expected interface, you can do anything you want.

5. `event_handler` - an instance of event handler/storage, just use what is shown in the example.
6. `clock` - a clock object that is time-zone aware, implementing `now` method.
7. `configure_hutch` - a way to specify `hutch uri`, basically the URI for RabbitMQ.
8. `event_handler.handle_events` - that's how you declare events and their handlers. The event handler is an object that responds to `call` method and takes `event` as an argument. All events should ideally be subclasses of `Hermes::BaseEvent`

This class inherits from `Dry::Struct`, so getting familiar with [dry-struct gem](https://dry-rb.org/gems/dry-struct/) would be beneficial. Here is an example event:

``` rb
class Payment::MarkedAsPaid < Hermes::BaseEvent
  attribute :payment_id, Types::Strict::Integer
  attribute :cents, Types::Strict::Integer
  attribute :currency, Types::Strict::String
end
```

To keep things clean, you might want to prefix the namespace with `Events`:

``` rb
class Events::Payment::MarkedAsPaid < Hermes::BaseEvent
  attribute :payment_id, Types::Strict::Integer
  attribute :cents, Types::Strict::Integer
  attribute :currency, Types::Strict::String
end
```

In both cases, the routing key will be the same (`Events` prefix is dropped) and will resolve to `payment.marked_as_paid`

To avoid unexpected problems, don't use restricted names for attribtes such as `meta`, `routing_key`, `origin_headers`, `origin_body`, `trace_context`, `version`.

You can also specify whether the event should be processed asynchronously using `background_processor` (default behavior) or synchronously. If you want the event to be processed synchronously, e.g. when doing RPC, use `async: false` option.

9. `rpc_call_timeout` - a timeout for RPC calls, defaults to 10 seconds. Can be also customized per instance of RPC Client (covered later).

10. `instrumenter` - instrumenter object responding to `instrument` method taking one string argument, one optional hash argument and a block.

For example:

``` rb
module Instrumenter
  extend ::NewRelic::Agent::MethodTracer

  def self.instrument(name, payload = {})
    ActiveSupport::Notifications.instrument(name, payload) do
      self.class.trace_execution_scoped([name]) do
        yield if block_given?
      end
    end
  end
end
```

If you don't care about it, you can leave it empty.

11. `distributed_tracing_database_uri` - If you want to enable distributed tracing, specify Postgres database URI

12. `distributed_tracing_database_table` - Table name for storing traces, by default it's `hermes_distributed_traces`.

13. `distributes_tracing_mapper` - an object responding to `call` method taking one argument (a hash of attributes) that has to return a hash as well. This hash will be used for assigning attributes when creating `Hermes::DistributedTrace`. The default mapper just returns the original hash. You can use it if you want to remove, for example, some sensitive info from the event's body.

## RPC

If you want to handle RPC call, you need to add `rpc: true` flag. Keep in mind that RPC requires a synchronous processing and response, so you also need to set `async: false`. The routing key and correlation ID will be resolved based on the message that is published by the client. The payload that is sent back will be what event handler reutrns, so it might be a good idea to just return a hash so that you can operate on JSON easily.

## Publishing

To publish an async event call `Hermes::Publisher`:

``` rb
Hermes::EventProducer.publish(event)
```

`event` is an instance of a subclass of `Events::BaseEvent`.

If you want to perform a synchronous RPC call, use `Hermes::RpcClient`:

``` rb
parsed_response_hash = Hermes::RpcClient.call(event)
```

You can also use an explicit initializer and provide custom `rpc_call_timeout`:

``` rb
parsed_response_hash = Hermes::RpcClient.new(rpc_call_timeout: 10).call(event)
```

If the request timeouts, `Hermes::RpcClient::RpcTimeoutError` will be raised.

## Distributed Tracing (Beta feature, the interface might change in the future)

If you want to take advantage of distributed tracing, you need to specify `distributed_tracing_database_uri` in the config and in many cases that will be enough, although there are some cases where some extra code will be required to properly use it.

If you have a "standard" flow, which means producing events and then consuming them in the jobs specified by `background_processor` and publishing other events from the same class, then you don't need to do anything extra as things will be handled out-of-box. In such scenario, at least two `Hermes::DistributedTrace` will be created (one for producer, and the rest for consumers and then potential other traces if the consumer also published some events).

However, if you enqueue some job inside the job specified by `background_processor`, you will need to do something extra:

1. You need to pass `origin_headers` as an argument to the job to have headers available. You can extract them inside the handler from the event by calling `event.origin_headers`
2. When processing the job, you will need to assign these headers to `Hermes`: 

``` rb
Hermes.origin_headers = origin_headers
```

These `origin_headers` will be stored in `RequestStore.store` (it uses [request_store](https://github.com/steveklabnik/request_store)).

Traces are also stored for RPC calls. For a single RPC, there will be traces:
1. Client (the actual RPC call)
2. Server (processing the request)
3. Client (processing the response) - that one uses a special internal event to keep the consistency: `ResponseEvent`, which stores `response_body` as a hash.


You will also need to create an appropriate database table:

``` rb
create_table(:hermes_distributed_traces) do |t|
  t.string "trace", null: false
  t.string "span", null: false
  t.string "parent_span"
  t.string "service", null: false
  t.text "event_class", null: false
  t.text "routing_key", null: false
  t.jsonb "event_body", null: false, default: []
  t.jsonb "event_headers", null: false, default: []
  t.datetime "created_at", precision: 6, null: false
  t.datetime "updated_at", precision: 6, null: false

  t.index ["created_at"], name: "index_hermes_distributed_traces_on_created_at", using: :brin
  t.index ["trace"], name: "index_hermes_distributed_traces_on_trace"
  t.index ["span"], name: "index_hermes_distributed_traces_on_span"
  t.index ["service"], name: "index_hermes_distributed_traces_on_service"
  t.index ["event_class"], name: "index_hermes_distributed_traces_on_event_class"
  t.index ["routing_key"], name: "index_hermes_distributed_traces_on_routing_key"
end 
```

Some important attributes to understand which will be useful during potential debugging:

1. `trace` - ID of the trace - all events from the same saga will have the same value (and that's why it's important to properly deal with `origin_headers`).
2. `span` - ID of the operation.
3. `parent span` - span value of the previous operation from the previous service.
4. `service` - name of the service where the given event occured, based on `application_prefix`,
 
It is highly recommended to use a shared database for storing traces. It's not ideal, but the benefits of storing traces in a single DB shared by the applications outweigh the disadvantages in many cases.  

## Testing

### RSpec useful stuff

Put this inside `rails_helper`. Note that it requires `webmock` and `sidekiq`.

``` rb
  def execute_jobs_inline
    original_active_job_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :inline
    Sidekiq::Testing.inline! do
      yield
    end
    ActiveJob::Base.queue_adapter = original_active_job_adapter
  end

  config.around(:example, :inline_jobs) do |example|
    execute_jobs_inline { example.run }
  end

  class ActiveRecord::Base
    mattr_accessor :shared_connection

    def self.connection
      shared_connection.presence || retrieve_connection
    end
  end

  config.after(:each) do
    Hermes::Publisher.instance.reset
  end

  config.before(:each, :with_rabbit_mq) do
    ActiveRecord::Base.shared_connection = ActiveRecord::Base.connection

    stub_request(:get, "http://127.0.0.1:15672/api/exchanges")
    stub_request(:get, "http://127.0.0.1:15672/api/bindings")

    hutch_publisher = Hermes::Publisher::HutchAdapter.new
    Hermes::Publisher.instance.current_adapter = hutch_publisher

    @worker_thread = Thread.new do
      Hutch.connect

      worker = Hutch::Worker.new(Hutch.broker, Hutch.consumers, Hutch::Config.setup_procs)
      worker.run
    end

    sleep 0.2
  end

  config.after(:each, :with_rabbit_mq) do |example|
    @worker_thread.kill
  end
```

To run integrations specs (with real RabbitMQ process), use `inline_jobs` and `with_rabbit_mq` meta flags.

#### Example integration spec with RabbitMQ

``` rb
require "rails_helper"

RSpec.describe "Example Event Test", :with_rabbit_mq, :inline_jobs do
  describe "when Events::Example::Happened is published" do
    subject(:publish_event) { Hermes::EventProducer.publish(event) }

    let(:event) { Events::Example::Happened.new(event_params) }
    let(:event_params) do
      {
        name: name
      }
    end
    let(:name) { "hermes" }

    it "calls Example::HappenedHandler" do
      expect(Example::HappenedHandler).to receive(:call)
        .with(instance_of(Events::Example::Happened)).and_call_original

      publish_event
      sleep 0.2 # since this is an async action, some delay will be required, either with a simple way like this, or you may want to go with something more complex to not put ugly `sleep` here
    end
  end
end

```

### Matchers

E.g. in `spec/supports/matchers/publish_async_message`:

``` rb
require "hermes/support/matchers/publish_async_message"
```

And then use it in the following way:

``` rb
expect {
  call
}.to publish_async_message(routing_key_of_the_expected_event).with_event_payload(expected_event_payload)
```

Note that `expected_event_payload` does not contain extra `meta` key that is added by Hermes publisher, it's just a symbolized hash with the result of the serialization of the event.

### Example test of HermesHandlerJob

``` rb
require "rails_helper"

RSpec.describe HermesHandlerJob do
  it { is_expected.to be_processed_in :critical }

  describe "#perform" do
    subject(:perform) { described_class.new.perform(EventClassForTestingHermesHandlerJob.to_s, payload, headers) }

    let(:configuration) { Hermes.configuration }
    let(:event_handler) { Hermes::EventHandler.new }
    let(:payload) do
      {
        "bookingsync" => "hermes"
      }
    end
    let(:headers) do
      {}
    end
    class EventClassForTestingHermesHandlerJob < Hermes::BaseEvent
      attribute :bookingsync, Types::Strict::String
    end
    class HandlerForEventClassForTestingHermesHandlerJob
      def self.event
        @event
      end

      def self.call(event)
        @event = event
      end
    end

    before do
      event_handler.handle_events do
        handle EventClassForTestingHermesHandlerJob, with: HandlerForEventClassForTestingHermesHandlerJob
      end
    end

    around do |example|
      original_event_handler = configuration.event_handler

      Hermes.configure do |config|
        config.event_handler = event_handler
      end

      example.run

      Hermes.configure do |config|
        config.event_handler = original_event_handler
      end
    end

    it "calls proper handler with a given event" do
      perform

      expect(HandlerForEventClassForTestingHermesHandlerJob.event).to be_a(EventClassForTestingHermesHandlerJob)
      expect(HandlerForEventClassForTestingHermesHandlerJob.event.bookingsync).to eq "hermes"
    end
  end
end
```

## Deployment and managing consumerzs

Hermes is just an extra later on top of [hutch](https://github.com/gocardless/hutch), refer to Hutch's docs for more info about dealing with the workers and deployment.

## CircleCI config for installing RabbitMQ

Use `- image: brandembassy/rabbitmq:latest`

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/BookingSync/hermes-rb.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
