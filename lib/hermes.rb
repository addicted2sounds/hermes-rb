require "hermes/base_event"
require "hermes/configuration"
require "hermes/consumer_builder"
require "hermes/event_handler"
require "hermes/event_processor"
require "hermes/event_producer"
require "hermes/publisher"
require "hermes/publisher_factory"
require "hermes/serializer"
require "hermes/rpc_client"
require "hermes/null_instrumenter"
require "hermes/logger"
require "hermes/rb"
require "hermes/b_3_propagation_model_headers"
require "hermes/trace_context"
require "hermes/distributed_trace_repository"
require "hermes/dependencies_container"
require "dry/struct"
require "active_support"
require "active_support/core_ext/string"
require "active_record"
require "request_store"

module Hermes
  def self.configuration
    @configuration ||= Hermes::Configuration.new
  end

  def self.configure
    yield configuration
  end

  ORIGIN_HEADERS_KEY = :__hermes__origin_headers
  private_constant :ORIGIN_HEADERS_KEY

  def self.origin_headers
    DependenciesContainer["global_store"][ORIGIN_HEADERS_KEY].to_h
  end

  def self.origin_headers=(headers)
    DependenciesContainer["global_store"][ORIGIN_HEADERS_KEY] = headers.to_h
  end
end

require "hermes/distributed_trace"
