module Hermes
  class DistributedTraceRepository
    attr_reader :config, :distributed_trace_database, :distributes_tracing_mapper
    private     :config, :distributed_trace_database, :distributes_tracing_mapper

    def initialize(config:, distributed_trace_database:, distributes_tracing_mapper:)
      @config = config
      @distributed_trace_database = distributed_trace_database
      @distributes_tracing_mapper = distributes_tracing_mapper
    end

    def create(event)
      if config.store_distributed_traces?
        trace_context = event.trace_context

        attributes = distributes_tracing_mapper.call(
          trace: trace_context.trace,
          span: trace_context.span,
          parent_span: trace_context.parent_span,
          service: trace_context.service,
          event_class: event.class.to_s,
          routing_key: event.routing_key,
          event_body: event.as_json,
          event_headers: event.to_headers
        )
        distributed_trace_database.create!(attributes)
      end
    end
  end
end
