# typed: true

module InfluxDBClient3; end

module PyCall
  def self.init(*args); end

  module Import
    def self.pyfrom(*args); end

    def self.import(*args); end
  end

  class PyError; end # rubocop:disable Lint/EmptyClass
end
