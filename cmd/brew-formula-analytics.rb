#:  * `formula-analytics` [`--days-ago=`<days>] [`--build-error`|`--install-on-request`|`--install`] [`--json`] [<formula>]:
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
VENDOR_RUBY = "#{REPO_ROOT}/vendor/ruby"
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
  json_key_io: File.open(CREDENTIALS_PATH),
  scope: API_SCOPE,
)

formula = ARGV.named.first
days_ago = ARGV.value("days-ago") || 30
category = if ARGV.include?("--build-error")
  :BuildError
elsif ARGV.include?("--install-on-request")
  :install_on_request
else
  :install
end
json_output = ARGV.include?("--json")

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

if formula
  dimension_filter_clauses << DimensionFilterClause.new(
    operator: "OR",
    filters: [
      DimensionFilter.new(
        dimension_name: "ga:eventAction",
        expressions: [formula],
        operator: "EXACT",
      ),
      DimensionFilter.new(
        dimension_name: "ga:eventAction",
        expressions: ["#{formula} "],
        operator: "BEGINS_WITH",
      ),
    ],
  )
end

dimension = Dimension.new name: "ga:eventAction"
metric = Metric.new expression: "ga:totalEvents"
order_by = OrderBy.new field_name: "ga:totalEvents",
                       sort_order: "DESCENDING"
date_range = DateRange.new start_date: "#{days_ago}daysAgo",
                           end_date: "today"

report_request = ReportRequest.new(
  view_id: ANALYTICS_VIEW_ID,
  dimensions: [dimension],
  metrics: [metric],
  order_bys: [order_by],
  date_ranges: [date_range],
  dimension_filter_clauses: dimension_filter_clauses,
)

analytics_reporting_service = AnalyticsReportingService.new
analytics_reporting_service.authorization = credentials
get_reports_request = GetReportsRequest.new
get_reports_request.report_requests = [report_request]
response = analytics_reporting_service.batch_get_reports(get_reports_request)

row_count = response.reports.first.data.row_count.to_i
odie "No data found!" if row_count.zero?

total_count = response.reports.first.data.totals.first.values.first.to_i

json = {
  category: category,
  total_items: row_count,
  start_date: Date.today - days_ago.to_i,
  end_date: Date.today,
  total_count: total_count,
  items: [],
}
json[:formula] = formula if formula

def format_count(count)
  count.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
end

def format_percent(percent)
  format "%.2f", percent
end

response.reports.first.data.rows.each_with_index do |row, index|
  count = row.metrics.first.values.first
  percent = (count.to_f / total_count.to_f) * 100

  json[:items] << {
    number: index + 1,
    formula: row.dimensions.first,
    count: format_count(count),
    percent: format_percent(percent),
  }
end

total_count = format_count(total_count)
total_percent = "100"

number_width = row_count.to_s.length
count_width = total_count.length
percent_width = format_percent("100").length
formula_width = Tty.width - number_width - count_width - percent_width - 10

if json_output
  puts JSON.pretty_generate json
else
  title = "#{category} events in the last #{days_ago} days"
  title += " for #{formula}" if formula
  puts title
  puts "=" * Tty.width
  (json[:items]).each do |item|
    number = format "%#{number_width}s", item[:number]
    formula = format "%-#{formula_width}s", item[:formula][0..formula_width-1]
    count = format "%#{count_width}s", item[:count]
    percent = format "%#{percent_width}s", item[:percent]
    puts "#{number} | #{formula} | #{count} | #{percent}%"
  end
  puts "=" * Tty.width
  total = format "%-#{formula_width + number_width + 3}s", "Total"
  total_count = format "%#{count_width}s", total_count
  total_percent = format "%#{percent_width}s", total_percent
  puts "#{total} | #{total_count} | #{total_percent}%"
  puts "=" * Tty.width
end
