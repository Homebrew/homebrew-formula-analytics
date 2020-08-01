require "cli/parser"

module Homebrew
  module_function

  def formula_analytics_args
    Homebrew::CLI::Parser.new do
      usage_banner <<~EOS
        `formula-analytics`

        Query Homebrew's anaytics for formula information. The top 10,000 formulae will be shown.
      EOS
      flag   "--days-ago=",
             description: "Query from the specified days ago until the present. The default is 30 days."
      switch "--install",
             description: "Show the number of specifically requested installations or installation as "\
                          "dependencies of the formula. This is the default."
      switch "--cask-install",
             description: "Show the number of installations of casks."
      switch "--install-on-request",
             description: "Show the number of specifically requested installations of the formula."
      switch "--build-error",
             description: "Show the number of build errors for the formulae."
      switch "--os-version",
             description: "Output OS versions rather than formulae names."
      switch "--json",
             description: "Output JSON. This is required: plain text support has been removed."
      switch "--all-core-formulae-json",
             description: "Output a different JSON format containing the JSON data for all " \
                          "Homebrew/homebrew-core formulae."
      switch "--setup",
             description: "Install the necessary gems, require them and exit without running a query."
      switch "--linux",
             description: "Read analytics from Homebrew on Linux's Google Analytics account."
      conflicts "--install", "--cask-install", "--install-on-request", "--build-error", "--os-version"
      conflicts "--json", "--all-core-formulae-json", "--setup"
      max_named 0
    end
  end

  REPO_ROOT = Pathname.new("#{File.dirname(__FILE__)}/..").freeze
  VENDOR_RUBY = "#{REPO_ROOT}/vendor/ruby".freeze
  BUNDLER_SETUP = Pathname.new("#{VENDOR_RUBY}/bundler/setup.rb").freeze
  API_SCOPE = "https://www.googleapis.com/auth/analytics.readonly".freeze
  ANALYTICS_VIEW_ID_LINUX = "120391035".freeze
  ANALYTICS_VIEW_ID_MACOS = "120682403".freeze
  CREDENTIALS_PATH = "#{ENV["HOME"]}/.homebrew_analytics.json".freeze
  FIRST_ANALYTICS_DATE = Date.parse("21 Apr 2016").freeze

  def formula_analytics
    args = formula_analytics_args.parse

    # Configure RubyGems.
    require "rubygems"

    unless BUNDLER_SETUP.exist?
      Homebrew.install_gem_setup_path! "bundler"

      REPO_ROOT.cd do
        safe_system "bundle", "install", "--standalone", "--path", "vendor/ruby"
      end
    end

    require "rbconfig"
    ENV["GEM_HOME"] = ENV["GEM_PATH"] = "#{VENDOR_RUBY}/#{RUBY_ENGINE}/#{RbConfig::CONFIG["ruby_version"]}"
    Gem.clear_paths
    Gem::Specification.reset

    require_relative BUNDLER_SETUP
    require "google/apis/analyticsreporting_v4"
    require "googleauth"

    include Google::Apis::AnalyticsreportingV4
    include Google::Auth

    analytics_view_id = if args.linux?
      ANALYTICS_VIEW_ID_LINUX
    else
      ANALYTICS_VIEW_ID_MACOS
    end

    # https://www.rubydoc.info/github/google/google-api-ruby-client/Google/Apis/AnalyticsreportingV4/AnalyticsReportingService
    analytics_reporting_service = AnalyticsReportingService.new

    return if args.setup?

    odie "No Google Analytics credentials found at #{CREDENTIALS_PATH}!" unless File.exist? CREDENTIALS_PATH

    odie "HOMEBREW_NO_ANALYTICS is set!" if ENV["HOMEBREW_NO_ANALYTICS"]

    # Using a service account:
    # https://developers.google.com/api-client-library/ruby/auth/service-accounts
    credentials = ServiceAccountCredentials.make_creds(
      # Need to pass an open file descriptor here
      json_key_io: File.open(CREDENTIALS_PATH),
      scope:       API_SCOPE,
    )
    analytics_reporting_service.authorization = credentials

    max_days_ago = (Date.today - FIRST_ANALYTICS_DATE).to_i
    days_ago = (args.days_ago || 30).to_i
    if days_ago > max_days_ago
      opoo "Analytics started #{FIRST_ANALYTICS_DATE}. `--days-ago` set to maximum value."
      days_ago = max_days_ago
    end

    json_output = args.json?
    os_version = args.os_version?
    all_core_formulae_json = args.all_core_formulae_json?
    json_output ||= all_core_formulae_json
    odie "Only JSON output is now supported!" unless json_output

    categories = []
    categories << :install if args.install?
    categories << :cask_install if args.cask_install?
    categories << :install_on_request if args.install_on_request?
    categories << :BuildError if args.build_error?
    categories += [:install] if categories.empty?

    report_requests = []

    categories.each do |category|
      dimension_filter_clauses = [
        DimensionFilterClause.new(
          filters: [
            DimensionFilter.new(
              dimension_name: "ga:eventCategory",
              expressions:    [category],
              operator:       "EXACT",
            ),
          ],
        ),
      ]

      if all_core_formulae_json
        dimension_filter_clauses << DimensionFilterClause.new(
          operator: "OR",
          filters:  [
            DimensionFilter.new(
              dimension_name: "ga:eventAction",
              expressions:    ["/"],
              operator:       "PARTIAL",
              not:            true,
            ),
          ],
        )
      end

      dimension = if os_version
        dimension_filter_clauses << DimensionFilterClause.new(
          operator: "AND",
          filters:  [
            DimensionFilter.new(
              dimension_name: "ga:operatingSystemVersion",
              not:            true,
              expressions:    ["Intel"],
              operator:       "EXACT",
            ),
            DimensionFilter.new(
              dimension_name: "ga:operatingSystemVersion",
              not:            true,
              expressions:    ["Intel 10.90"],
              operator:       "EXACT",
            ),
            DimensionFilter.new(
              dimension_name: "ga:operatingSystemVersion",
              not:            true,
              expressions:    ["(not set)"],
              operator:       "EXACT",
            ),
          ],
        )
        Dimension.new name: "ga:operatingSystemVersion"
      else
        Dimension.new name: "ga:eventAction"
      end
      metric = Metric.new expression: "ga:totalEvents"
      order_by = OrderBy.new field_name: "ga:totalEvents",
                             sort_order: "DESCENDING"
      date_range = DateRange.new start_date: "#{days_ago}daysAgo",
                                 end_date:   "today"

      # https://www.rubydoc.info/github/google/google-api-ruby-client/Google/Apis/AnalyticsreportingV4/ReportRequest
      report_requests << ReportRequest.new(
        view_id:                  analytics_view_id,
        dimensions:               [dimension],
        metrics:                  [metric],
        order_bys:                [order_by],
        date_ranges:              [date_range],
        dimension_filter_clauses: dimension_filter_clauses,
        page_size:                10_000,
        sampling_level:           :LARGE,
      )
    end

    reports = []

    get_reports_request = GetReportsRequest.new
    report_requests.each_slice(50) do |report_requests_slice|
      # batch multiple HTTP calls into a single request
      # https://developers.google.com/api-client-library/ruby/guide/batch
      analytics_reporting_service.batch do |service|
        # batch reporting API will only allow 5 requests at a time
        report_requests_slice.each_slice(5) do |rr|
          get_reports_request.report_requests = rr
          service.batch_get_reports(
            get_reports_request,
          ) do |response, error|
            raise error if error

            reports += response.reports
          end
        end
      end
    end

    dimension_key = if os_version
      :os_version
    elsif categories.include?(:cask_install)
      :cask
    else
      :formula
    end

    reports.each_with_index do |report, index|
      first_report = index.zero?
      puts unless first_report

      category = if categories.length > 1
        categories.at index
      else
        categories.first
      end

      row_count = report.data.row_count.to_i
      if row_count.zero?
        onoe "No #{category} data found!"
        next
      end

      total_count = report.data.totals.first.values.first.to_i

      json = {
        category:    category,
        total_items: row_count,
        start_date:  Date.today - days_ago.to_i,
        end_date:    Date.today,
        total_count: total_count,
      }

      report.data.rows.each_with_index do |row, row_index|
        count = row.metrics.first.values.first
        percent = (count.to_f / total_count) * 100
        dimension = format_dimension(row.dimensions.first, dimension_key)
        item = {
          number: row_index + 1,
          dimension_key => dimension,
          count: format_count(count),
          percent: format_percent(percent),
        }

        if all_core_formulae_json
          item.delete(:number)
          item.delete(:percent)
          formula_name = dimension.split.first.downcase.to_sym
          json[:formulae] ||= {}
          json[:formulae][formula_name] ||= []
          json[:formulae][formula_name] << item
        else
          json[:items] ||= []
          json[:items] << item
        end
      end

      json[:formulae] = Hash[json[:formulae].sort_by { |name, _| name }] if all_core_formulae_json

      puts JSON.pretty_generate json
    end
  end

  def format_count(count)
    count.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
  end

  def format_percent(percent)
    format "%<percent>.2f", percent: percent
  end

  def format_dimension(dimension, key)
    return dimension if key != :os_version

    dimension.gsub!(/^Intel ?/, "")
    case dimension
    when "10.4" then "Mac OS X Tiger (10.4)"
    when "10.5" then "Mac OS X Leopard (10.5)"
    when "10.6" then "Mac OS X Snow Leopard (10.6)"
    when "10.7" then "Mac OS X Lion (10.7)"
    when "10.8" then "OS X Mountain Lion (10.8)"
    when "10.9" then "OS X Mavericks (10.9)"
    when "10.10" then "OS X Yosemite (10.10)"
    when "10.11" then "OS X El Capitan (10.11)"
    when "10.12" then "macOS Sierra (10.12)"
    when "10.13" then "macOS High Sierra (10.13)"
    when "10.14" then "macOS Mojave (10.14)"
    when "10.15" then "macOS Catalina (10.15)"
    when "10.16", "11.0" then "macOS Big Sur (#{dimension})"
    when /\d+\.\d+/ then "macOS (#{dimension})"
    when "" then "Unknown"
    else dimension
    end
  end
end
