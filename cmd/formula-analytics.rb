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

  REPO_ROOT = Pathname.new("#{File.dirname(__FILE__)}/..").expand_path.freeze
  VENDOR_RUBY = (REPO_ROOT/"vendor/ruby").freeze
  VENDOR_PYTHON = (REPO_ROOT/"vendor/python").freeze
  BUNDLER_SETUP = (VENDOR_RUBY/"bundler/setup.rb").freeze
  PYTHON_VERSION = (REPO_ROOT/".python-version").read.chomp.freeze
  FIRST_INFLUXDB_ANALYTICS_DATE = Date.new(2023, 03, 27).freeze

  def formula_analytics
    args = formula_analytics_args.parse

    setup_ruby
    setup_python
    influx_analytics(args)
  end

  def setup_ruby
    # System Ruby does not pick up the correct SDK by default.
    ENV["SDKROOT"] = MacOS.sdk_path_if_needed if OS.mac?

    Homebrew.install_bundler!
    REPO_ROOT.cd do
      if !BUNDLER_SETUP.exist? || !quiet_system("bundle", "check", "--path", "vendor/ruby")
        safe_system "bundle", "install", "--standalone", "--path", "vendor/ruby", out: :err
      end
    end

    require_relative BUNDLER_SETUP
  end

  def setup_python
    venv_root = VENDOR_PYTHON/PYTHON_VERSION
    VENDOR_PYTHON.children.reject { |path| path == venv_root }.each(&:rmtree) if VENDOR_PYTHON.exist?
    venv_python = venv_root/"bin/python"

    repo_requirements = REPO_ROOT/"requirements.txt"
    venv_requirements = venv_root/"requirements.txt"
    if !venv_requirements.exist? || !FileUtils.identical?(repo_requirements, venv_requirements)
      safe_system "python#{PYTHON_VERSION}", "-I", "-m", "venv", "--clear", venv_root, out: :err
      safe_system venv_python, "-m", "pip", "install",
                  "--disable-pip-version-check",
                  "--require-hashes",
                  "--requirement", repo_requirements,
                  out: :err
      FileUtils.cp repo_requirements, venv_requirements
    end

    ENV["PATH"] = "#{venv_root}/bin:#{ENV.fetch("PATH")}"
    ENV["__PYVENV_LAUNCHER__"] = venv_python # support macOS framework Pythons

    require "pycall/import"
    PyCall.init(venv_python)
    PyCall.sys.setdlopenflags(PyCall.sys.getdlopenflags | PyCall.import_module("os").RTLD_DEEPBIND) if OS.linux?
    extend PyCall::Import
  end

  def influx_analytics(args)
    require "utils/analytics"
    require "json"
    pyfrom "flightsql.client", import: :FlightSQLClient

    return if args.setup?

    odie "HOMEBREW_NO_ANALYTICS is set!" if ENV["HOMEBREW_NO_ANALYTICS"]

    token = ENV.fetch("HOMEBREW_INFLUXDB_TOKEN", nil)
    odie "No InfluxDB credentials found in HOMEBREW_INFLUXDB_TOKEN!" unless token

    client = FlightSQLClient.new(
      host:     URI.parse(Utils::Analytics::INFLUX_HOST).host,
      token:    token,
      metadata: { database: Utils::Analytics::INFLUX_BUCKET },
    )

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

    category_matching_buckets = [:build_error, :cask_install]

    categories.each do |category|
      additional_where = all_core_formulae_json ? " AND tap_name ~ '^homebrew/(core|cask)$'" : ""
      bucket = category_matching_buckets.include?(category) ? category : :formula_install

      case category
      when :homebrew_devcmdrun_developer
        dimension_key = "devcmdrun_developer"
        groups = [:devcmdrun, :developer]
      when :homebrew_os_arch_ci
        dimension_key = "os_arch_ci"
        groups = [:os, :arch, :ci]
      when :homebrew_prefixes
        dimension_key = "prefix"
        groups = [:prefix, :os, :arch]
      when :homebrew_versions
        dimension_key = "version"
        groups = [:version]
      when :os_versions
        dimension_key = :os_version
        groups = [:os_name_and_version]
      when :cask_install
        dimension_key = :cask
        groups = [:package, :tap_name]
      else
        dimension_key = :formula
        additional_where += " AND on_request = 'true'" if category == :formula_install_on_request
        groups = [:package, :tap_name, :options]
      end

      sql_groups = groups.map { |e| "\"#{e}\"" }.join(",")
      query = <<~EOS
        SELECT #{sql_groups}, COUNT(*) AS "count" FROM "#{bucket}" WHERE time >= now() - INTERVAL '#{days_ago} day'#{additional_where} GROUP BY #{sql_groups}
      EOS
      info = client.execute(query)
      reader = client.do_get(info.endpoints[0].ticket)

      json = {
        category:    category,
        total_items: 0,
        start_date:  Date.today - days_ago.to_i,
        end_date:    Date.today,
        total_count: 0,
        items:       [],
      }

      PyCall.iterable(reader).each do |chunk|
        chunk.data.to_pylist.each do |result|
          dimension = case category
          when :homebrew_devcmdrun_developer
            "devcmdrun=#{result["devcmdrun"]} HOMEBREW_DEVELOPER=#{result["developer"]}"
          when :homebrew_os_arch_ci
            if result["ci"] == "true"
              "#{result["os"]} #{result["arch"]} (CI)"
            else
              "#{result["os"]} #{result["arch"]}"
            end
          when :homebrew_prefixes
            if result["prefix"] == "custom-prefix"
              "#{result["prefix"]} (#{result["os"]} #{result["arch"]})"
            else
              (result["prefix"]).to_s
            end
          when :os_versions
            format_os_version_dimension(result["os_name_and_version"])
          else
            result[groups.first.to_s]
          end
          next if dimension.blank?

          if (tap_name = result["tap_name"].presence) &&
             ((tap_name != "homebrew/cask" && dimension_key == :cask) ||
              (tap_name != "homebrew/core" && dimension_key == :formula))
            dimension = "#{tap_name}/#{dimension}"
          end

          if (all_core_formulae_json || category == :build_error) &&
             (options = result["options"].presence)
            dimension = "#{dimension} #{options}"
          end

          dimension = dimension.strip

          count = result["count"]

          json[:total_items] += 1
          json[:total_count] += count

          json[:items] << {
            number: nil,
            dimension_key => dimension,
            count: count,
          }
        end
      end

      odie "No data returned" if json[:total_count].zero?

      # Combine identical values
      deduped_items = {}

      json[:items].each do |item|
        key = item[dimension_key]
        if deduped_items.key?(key)
          deduped_items[key][:count] += item[:count]
        else
          deduped_items[key] = item
        end
      end

      json[:items] = deduped_items.values

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

  def format_os_version_dimension(dimension)
    return if dimension.blank?

    dimension = dimension.gsub(/^Intel ?/, "")
                         .gsub(/^macOS ?/, "")
                         .gsub(/ \(.+\)$/, "")
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
    when %r{Debian GNU/Linux (\d+)\.\d+} then "Debian #{Regexp.last_match(1)} #{Regexp.last_match(2)}"
    when /CentOS (\w+) (\d+)/ then "CentOS #{Regexp.last_match(1)} #{Regexp.last_match(2)}"
    when /Fedora Linux (\d+)[.\d]*/ then "Fedora Linux #{Regexp.last_match(1)}"
    when /KDE neon .*([\d.]+)/ then "KDE neon #{Regexp.last_match(1)}"
    else dimension
    end
  end
end
