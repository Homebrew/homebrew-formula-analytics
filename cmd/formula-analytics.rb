# frozen_string_literal: true

require "cli/parser"

module Homebrew
  module_function

  def formula_analytics_args
    Homebrew::CLI::Parser.new do
      usage_banner <<~EOS
        `formula-analytics`

        Query Homebrew's analytics.
      EOS
      flag   "--days-ago=",
             description: "Query from the specified days ago until the present. The default is 30 days."
      switch "--install",
             description: "Output the number of specifically requested installations or installation as " \
                          "dependencies of the formula. This is the default."
      switch "--cask-install",
             description: "Output the number of installations of casks."
      switch "--install-on-request",
             description: "Output the number of specifically requested installations of the formula."
      switch "--build-error",
             description: "Output the number of build errors for the formulae."
      switch "--os-version",
             description: "Output OS versions."
      switch "--homebrew-devcmdrun-developer",
             description: "Output devcmdrun/HOMEBREW_DEVELOPER."
      switch "--homebrew-os-arch-ci",
             description: "Output OS/Architecture/CI."
      switch "--homebrew-prefixes",
             description: "Output Homebrew prefixes."
      switch "--homebrew-versions",
             description: "Output Homebrew versions."
      switch "--json",
             description: "Output JSON. This is required: plain text support has been removed."
      switch "--all-core-formulae-json",
             description: "Output a different JSON format containing the JSON data for all " \
                          "Homebrew/homebrew-core formulae."
      switch "--setup",
             description: "Install the necessary gems, require them and exit without running a query."
      conflicts "--install", "--cask-install", "--install-on-request", "--build-error", "--os-version"
      conflicts "--json", "--all-core-formulae-json", "--setup"
      named_args :none
    end
  end

  REPO_ROOT = Pathname.new("#{File.dirname(__FILE__)}/..").freeze
  VENDOR_RUBY = "#{REPO_ROOT}/vendor/ruby"
  BUNDLER_SETUP = Pathname.new("#{VENDOR_RUBY}/bundler/setup.rb").freeze
  FIRST_INFLUXDB_ANALYTICS_DATE = Date.new(2023, 03, 27).freeze

  def formula_analytics
    args = formula_analytics_args.parse

    # Configure RubyGems.
    require "rubygems"

    Homebrew.install_bundler!
    REPO_ROOT.cd do
      if !BUNDLER_SETUP.exist? || !quiet_system("bundle", "check", "--path", "vendor/ruby")
        safe_system "bundle", "install", "--standalone", "--path", "vendor/ruby", out: :err
      end
    end

    require "rbconfig"
    ENV["GEM_HOME"] = ENV["GEM_PATH"] = "#{VENDOR_RUBY}/#{RUBY_ENGINE}/#{RbConfig::CONFIG["ruby_version"]}"
    Gem.clear_paths
    Gem::Specification.reset

    require_relative BUNDLER_SETUP

    influx_analytics(args)
  end

  def influx_analytics(args)
    require "utils/analytics"
    require "influxdb-client"

    token = if args.setup?
      Utils::Analytics::INFLUX_TOKEN
    else
      ENV.fetch("HOMEBREW_INFLUXDB_TOKEN", nil)
    end

    influxdb_client = InfluxDB2::Client.new(
      Utils::Analytics::INFLUX_HOST,
      token,
      bucket: Utils::Analytics::INFLUX_BUCKET,
      org:    Utils::Analytics::INFLUX_ORG,
    )

    return if args.setup?

    odie "HOMEBREW_NO_ANALYTICS is set!" if ENV["HOMEBREW_NO_ANALYTICS"]

    odie "No InfluxDB credentials found in HOMEBREW_INFLUXDB_TOKEN!" unless ENV["HOMEBREW_INFLUXDB_TOKEN"]

    max_days_ago = (Date.today - FIRST_INFLUXDB_ANALYTICS_DATE).to_i
    days_ago = (args.days_ago || 30).to_i
    if days_ago > max_days_ago
      opoo "Analytics started #{FIRST_INFLUXDB_ANALYTICS_DATE}. `--days-ago` set to maximum value."
      days_ago = max_days_ago
    end
    if days_ago > 365
      opoo "Analytics are only retained for 1 year, setting `--days-ago=365`."
      days_ago = 365
    end

    all_core_formulae_json = args.all_core_formulae_json?

    categories = []
    categories << :build_error if args.build_error?
    categories << :cask_install if args.cask_install?
    categories << :formula_install if args.install?
    categories << :formula_install_on_request if args.install_on_request?
    categories << :homebrew_devcmdrun_developer if args.homebrew_devcmdrun_developer?
    categories << :homebrew_os_arch_ci if args.homebrew_os_arch_ci?
    categories << :homebrew_prefixes if args.homebrew_prefixes?
    categories << :homebrew_versions if args.homebrew_versions?
    categories << :os_versions if args.os_version?

    categories.each do |category|
      case category
      when :homebrew_devcmdrun_developer
        dimension_key = field = tag = "devcmdrun_developer"
      when :homebrew_os_arch_ci
        dimension_key = field = tag = "os_arch_ci"
      when :homebrew_prefixes
        dimension_key = field = tag = "prefix"
      when :homebrew_versions
        dimension_key = field = tag = "version"
      when :os_versions
        dimension_key = :os_version
        field = "os_name_and_version"
        tag = "os"
      else
        dimension_key = if category == :cask_install
          :cask
        else
          :formula
        end
        field = "package"
        tag = "pkg"
      end

      query = <<~EOS
        from(bucket: "analytics_counts")
          |> range(start: -#{days_ago}d, stop: now())
          |> filter(fn: (r) => r._measurement == "#{category}" and r._field == "#{field}")
          |> group(columns: ["#{tag}"])
          |> sum(column: "_value")
      EOS
      result = influxdb_client.create_query_api.query_raw(query: query).force_encoding("UTF-8")
      lines = result.lines.drop(4)
      json = {
        category:    category,
        total_items: 0,
        start_date:  Date.today - days_ago.to_i,
        end_date:    Date.today,
        total_count: 0,
        items:       [],
      }

      lines.each do |line|
        _, _, _index, _start, _end, count, name = line.split(",")
        next if name.blank?

        dimension = format_dimension(name, dimension_key)

        count = count.to_i

        json[:total_items] += 1
        json[:total_count] += count

        json[:items] << {
          number: nil,
          dimension_key => dimension,
          count: count,
        }
      end

      # Combine identical OS versions
      if category == :os_versions
        os_version_items = {}

        json[:items].each do |item|
          os_version_name = item[dimension_key]
          if os_version_items.key?(os_version_name)
            os_version_items[os_version_name][:count] += item[:count]
          else
            os_version_items[os_version_name] = item
          end
        end

        json[:items] = os_version_items.values
      end

      if all_core_formulae_json
        core_formula_items = {}

        json[:items].each do |item|
          item.delete(:number)
          item[:count] = format_count(item[:count])

          formula_name = item[dimension_key]
          next if formula_name.include?("/")

          core_formula_items[formula_name] ||= []
          core_formula_items[formula_name] << item
        end

        json.delete(:items)
        json[:formulae] = core_formula_items.sort_by { |name, _| name }.to_h
      else
        json[:items].sort_by! do |item|
          -item[:count]
        end

        json[:items].each_with_index do |item, index|
          item[:number] = index + 1

          percent = (item[:count].to_f / json[:total_count]) * 100
          item[:percent] = format_percent(percent)
          item[:count] = format_count(item[:count])
        end
      end

      puts JSON.pretty_generate json
    end
  end

  def format_count(count)
    count.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
  end

  def format_percent(percent)
    format("%<percent>.2f", percent: percent).gsub(/\.00$/, "")
  end

  def format_dimension(dimension, key)
    dimension = dimension.chomp
    return dimension if key != :os_version

    dimension = dimension.gsub(/^Intel ?/, "")
                         .gsub(/^macOS ?/, "")
    case dimension
    when "10.4" then "Mac OS X Tiger (10.4)"
    when "10.5" then "Mac OS X Leopard (10.5)"
    when "10.6" then "Mac OS X Snow Leopard (10.6)"
    when "10.7" then "Mac OS X Lion (10.7)"
    when "10.8" then "OS X Mountain Lion (10.8)"
    when "10.9" then "OS X Mavericks (10.9)"
    when "10.10" then "OS X Yosemite (10.10)"
    when "10.11", /^10\.11\.?/ then "OS X El Capitan (10.11)"
    when "10.12", /^10\.12\.?/ then "macOS Sierra (10.12)"
    when "10.13", /^10\.13\.?/ then "macOS High Sierra (10.13)"
    when "10.14", /^10\.14\.?/ then "macOS Mojave (10.14)"
    when "10.15", /^10\.15\.?/ then "macOS Catalina (10.15)"
    when "10.16", /^11\.?/ then "macOS Big Sur (11)"
    when /^12\.?/ then "macOS Monterey (12)"
    when /^13\.?/ then "macOS Ventura (13)"
    when /^14\.?/ then "macOS Sonoma (14)"
    when /Ubuntu(-Server)? (14|16|18|20|22)\.04/ then "Ubuntu #{Regexp.last_match(2)}.04 LTS"
    when /Ubuntu(-Server)? (\d+\.\d+).\d ?(LTS)?/ then "Ubuntu #{Regexp.last_match(2)} #{Regexp.last_match(3)}".strip
    else dimension
    end
  end
end
