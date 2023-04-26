# frozen_string_literal: true

require "cli/parser"

module Homebrew
  module_function

  CATEGORIES = %w[
    build-error install install-on-request
    core-build-error core-install core-install-on-request
  ].freeze
  MAC_ONLY_CATEGORIES = %w[cask-install core-cask-install os-version].freeze
  DAYS = %w[30 90 365].freeze
  MAX_RETRIES = 3

  def generate_analytics_api_args
    Homebrew::CLI::Parser.new do
      description <<~EOS
        Generates analytics API data files for formulae.brew.sh.

        The generated files are written to the current directory.
      EOS

      named_args :none
    end
  end

  def analytics_json_template(category_name, data_source: nil)
    data_source = "#{data_source}: true" if data_source

    <<~EOS
      ---
      layout: analytics_json
      category: #{category_name}
      #{data_source}
      ---
      {{ content }}
    EOS
  end

  def run_formula_analytics(*args)
    puts "brew formula-analytics #{args.join(" ")}"

    retries = 0
    output, _, status = system_command HOMEBREW_BREW_FILE, args: ["formula-analytics", *args]

    while !status.success? && retries < MAX_RETRIES
      sleep 2**(retries + 3)
      retries += 1
      output, _, status = system_command HOMEBREW_BREW_FILE, args: ["formula-analytics", *args]
    end

    odie "`brew formula-analytics #{args.join(" ")}` failed" unless status.success?

    output
  end

  def generate_analytics_api
    generate_analytics_api_args.parse

    safe_system HOMEBREW_BREW_FILE, "formula-analytics", "--setup"

    directories = ["_data/analytics", "_data/analytics-linux", "api/analytics", "api/analytics-linux"]
    FileUtils.rm_rf directories
    FileUtils.mkdir_p directories

    root_dir = Pathname.pwd

    [:mac, :linux].each do |os|
      analytics_data_dir, analytics_api_dir = if os == :mac
        [root_dir/"_data/analytics", root_dir/"api/analytics"]
      else
        [root_dir/"_data/analytics-linux", root_dir/"api/analytics-linux"]
      end

      categories = CATEGORIES
      categories += MAC_ONLY_CATEGORIES if os == :mac

      categories.each do |category|
        formula_analytics_args = []

        case category
        when "core-build-error"
          formula_analytics_args << "--all-core-formulae-json"
          formula_analytics_args << "--build-error"
          category_name = "build-error"
          data_source = "homebrew-core"
        when "core-install"
          formula_analytics_args << "--all-core-formulae-json"
          formula_analytics_args << "--install"
          category_name = "install"
          data_source = "homebrew-core"
        when "core-install-on-request"
          formula_analytics_args << "--all-core-formulae-json"
          formula_analytics_args << "--install-on-request"
          category_name = "install-on-request"
          data_source = "homebrew-core"
        when "core-cask-install"
          formula_analytics_args << "--all-core-formulae-json"
          formula_analytics_args << "--cask-install"
          category_name = "cask-install"
          data_source = "homebrew-cask"
        else
          formula_analytics_args << "--#{category}"
          category_name = category
        end

        path_suffix = File.join(category_name, data_source || "")
        analytics_data_path = analytics_data_dir/path_suffix
        analytics_api_path = analytics_api_dir/path_suffix

        FileUtils.mkdir_p analytics_data_path
        FileUtils.mkdir_p analytics_api_path

        # The `--json` and `--all-core-formulae-json` flags are mutually
        # exclusive, but we need to explicitly set `--json` sometimes,
        # so only set it if we've not already set
        # `--all-core-formulae-json`.
        formula_analytics_args << "--json" unless formula_analytics_args.include? "--all-core-formulae-json"
        formula_analytics_args << "--linux" if os == :linux

        DAYS.each do |days|
          next if days != "30" && category_name == "build-error" && !data_source.nil?
          args = %W[--days-ago=#{days}]
          args << "--influxdb" if days == "30"

          output = run_formula_analytics(*formula_analytics_args, *args)
          (analytics_data_path/"#{days}d.json").write output
          (analytics_api_path/"#{days}d.json").write analytics_json_template(category_name, data_source: data_source)
        end
      end
    end
  end
end
