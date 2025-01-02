# typed: true

class InfluxDBClient3
  def self.initialize(*args); end

  def query(*args); end
end

module PyCall
  def self.init(*args); end

  module Import
    def self.pyfrom(*args); end

    def self.import(*args); end
  end

  PyError = Class.new(StandardError).freeze
end
