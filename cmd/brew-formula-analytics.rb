#:  * `formula-analytics` [`--days-ago=`<days>] [`--build-error`] [`--install-on-request`] [`--install`] [`--os-version`] [`--json`] [<formula>]:
#:    Query Homebrew's anaytics for formula information
#:
#:    If `--days-ago=<days>` is passed, the query is from the specified days ago until the present. The default is 30 days.
#:
#:    If `--build-error` is passed, the number of build errors for the formulae are shown.
#:
#:    If `--install-on-request` is passed, the number of specifically requested installations of the formula are shown.
#:
#:    If `--install` is passed, the number of specifically requested installations or installation as dependencies of the formula are shown. This is the default.
#:
#:    If `--os-version` is passed, output OS versions rather than formulae names.
#:
#:    If `--json` is passed, the output is in JSON rather than plain text.
#:
#:    If `<formula>` is passed, the results will be filtered to this formula. If this is not passed, the top 1000 formulae will be shown.
#:

CREDENTIALS_PATH = "#{ENV["HOME"]}/.homebrew_analytics.json".freeze
unless File.exist? CREDENTIALS_PATH
  odie "No Google Analytics credentials found at #{CREDENTIALS_PATH}!"
end

# Configure RubyGems.
REPO_ROOT = Pathname.new "#{File.dirname(__FILE__)}/.."
VENDOR_RUBY = "#{REPO_ROOT}/vendor/ruby".freeze
BUNDLER_SETUP = Pathname.new "#{VENDOR_RUBY}/bundler/setup.rb"
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

ANALYTICS_VIEW_ID = "120682403".freeze
API_SCOPE = "https://www.googleapis.com/auth/analytics.readonly".freeze

# Using a service account:
# https://developers.google.com/api-client-library/ruby/auth/service-accounts
credentials = ServiceAccountCredentials.make_creds(
  # Need to pass an open file descriptor here
  # rubocop:disable Style/AutoResourceCleanup
  json_key_io: File.open(CREDENTIALS_PATH),
  scope: API_SCOPE,
)

formula = ARGV.named.first

FIRST_ANALYTICS_DATE = Date.parse("21 Apr 2016").freeze
max_days_ago = (Date.today - FIRST_ANALYTICS_DATE).to_i
days_ago = (ARGV.value("days-ago") || 30).to_i
if days_ago > max_days_ago
  opoo "Analytics started #{FIRST_ANALYTICS_DATE}. `--days-ago` set to maximum value."
  days_ago = max_days_ago
end

json_output = ARGV.include?("--json")
os_version = ARGV.include?("--os-version")

categories = []
categories << :install if ARGV.include?("--install")
categories << :install_on_request if ARGV.include?("--install-on-request")
categories << :BuildError if ARGV.include?("--build-error")
if categories.empty?
  if json_output
    categories += [:install]
  else
    categories += [:install, :install_on_request, :BuildError]
  end
elsif categories.length > 1
  odie "Cannot specify multiple categories for JSON output!" if json_output
end

formula_name = if formula
  begin
    Formula[formula].full_name
  rescue
    formula
  end
end

report_requests = []

categories.each do |category|
  dimension_filter_clauses = [
    DimensionFilterClause.new(
      filters: [
        DimensionFilter.new(
          dimension_name: "ga:eventCategory",
          expressions: [category],
          operator: "EXACT",
        ),
      ],
    ),
  ]

  if formula_name
    dimension_filter_clauses << DimensionFilterClause.new(
      operator: "OR",
      filters: [
        DimensionFilter.new(
          dimension_name: "ga:eventAction",
          expressions: [formula_name],
          operator: "EXACT",
        ),
        DimensionFilter.new(
          dimension_name: "ga:eventAction",
          expressions: ["#{formula_name} "],
          operator: "BEGINS_WITH",
        ),
      ],
    )
  end

  dimension = if os_version
    dimension_filter_clauses << DimensionFilterClause.new(
      operator: "AND",
      filters: [
        DimensionFilter.new(
          dimension_name: "ga:operatingSystemVersion",
          not: true,
          expressions: ["Intel"],
          operator: "EXACT",
        ),
        DimensionFilter.new(
          dimension_name: "ga:operatingSystemVersion",
          not: true,
          expressions: ["Intel 10.90"],
          operator: "EXACT",
        ),
        DimensionFilter.new(
          dimension_name: "ga:operatingSystemVersion",
          not: true,
          expressions: ["(not set)"],
          operator: "EXACT",
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
                             end_date: "today"

  report_requests << ReportRequest.new(
    view_id: ANALYTICS_VIEW_ID,
    dimensions: [dimension],
    metrics: [metric],
    order_bys: [order_by],
    date_ranges: [date_range],
    dimension_filter_clauses: dimension_filter_clauses,
  )
end

analytics_reporting_service = AnalyticsReportingService.new
analytics_reporting_service.authorization = credentials
get_reports_request = GetReportsRequest.new
get_reports_request.report_requests = report_requests
response = analytics_reporting_service.batch_get_reports(get_reports_request)

dimension_key = os_version ? :os_version : :formula

def format_count(count)
  count.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
end

def format_percent(percent)
  format "%.2f", percent
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
  when /10\.\d+/ then "macOS (#{dimension})"
  when "" then "Unknown"
  else dimension
  end
end

response.reports.each_with_index do |report, index|
  first_report = index.zero?
  puts unless first_report

  category = categories.at index
  row_count = report.data.row_count.to_i
  if row_count.zero?
    onoe "No #{category} data found!"
    next
  end

  total_count = report.data.totals.first.values.first.to_i

  json = {
    category: category,
    total_items: row_count,
    start_date: Date.today - days_ago.to_i,
    end_date: Date.today,
    total_count: total_count,
    items: [],
  }
  json[:formula] = formula if formula

  report.data.rows.each_with_index do |row, row_index|
    count = row.metrics.first.values.first
    percent = (count.to_f / total_count.to_f) * 100

    json[:items] << {
      number: row_index + 1,
      dimension_key => format_dimension(row.dimensions.first, dimension_key),
      count: format_count(count),
      percent: format_percent(percent),
    }
  end

  total_count = format_count(total_count)
  total_percent = "100"

  number_width = row_count.to_s.length
  count_width = total_count.length
  percent_width = format_percent("100").length
  dimension_width = Tty.width - number_width - count_width - percent_width - 10

  if json_output
    puts JSON.pretty_generate json
    next
  end

  if first_report
    title = "#{category} events in the last #{days_ago} days"
    title += " for #{formula}" if formula
  else
    title = "#{category} events"
  end
  puts title
  puts "=" * Tty.width
  (json[:items]).each do |item|
    number = format "%#{number_width}s", item[:number]
    dimension = format "%-#{dimension_width}s", item[dimension_key][0..dimension_width-1]
    count = format "%#{count_width}s", item[:count]
    percent = format "%#{percent_width}s", item[:percent]
    puts "#{number} | #{dimension} | #{count} | #{percent}%"
  end
  puts "=" * Tty.width
  next unless json[:items].length > 1
  total = format "%-#{dimension_width + number_width + 3}s", "Total"
  total_count = format "%#{count_width}s", total_count
  total_percent = format "%#{percent_width}s", total_percent
  puts "#{total} | #{total_count} | #{total_percent}%"
  puts "=" * Tty.width
end
