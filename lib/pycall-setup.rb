# frozen_string_literal: true

require "pycall/import"

module InfluxDBClient3
  extend PyCall::Import

  pyfrom "influxdb_client_3", import: :InfluxDBClient3
end

# This was a rewrite from `include(Module.new(...))`,
# to appease Sorbet, so let's keep the existing behaviour
# as far as possible here and silence RuboCop.
include InfluxDBClient3 # rubocop:disable Style/MixinUsage
