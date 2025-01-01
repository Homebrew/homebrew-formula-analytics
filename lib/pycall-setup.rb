# typed: false
# frozen_string_literal: true

require "pycall/import"
include PyCall::Import # rubocop:disable Style/MixinUsage

pyfrom "influxdb_client_3", import: :InfluxDBClient3
