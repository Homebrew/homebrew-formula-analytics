# frozen_string_literal: true

require "pycall/import"

include(Module.new do
  extend PyCall::Import

  pyfrom "influxdb_client_3", import: :InfluxDBClient3
end)
