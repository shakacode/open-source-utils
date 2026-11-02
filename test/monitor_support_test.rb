# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/open_source_utils/monitor_support"

class MonitorSupportTest < Minitest::Test
  def test_active_repository_uses_latest_available_activity_timestamp
    cutoff = Time.utc(2025, 8, 10)
    repositories = [
      { "name" => "recent-push", "pushed_at" => "2026-01-01T00:00:00Z" },
      { "name" => "recent-update", "updated_at" => "2025-09-01T00:00:00Z", "pushed_at" => "2024-01-01T00:00:00Z" },
      { "name" => "new-repository", "created_at" => "2025-12-01T00:00:00Z" },
      { "name" => "inactive", "created_at" => "2020-01-01T00:00:00Z", "updated_at" => "2024-01-01T00:00:00Z", "pushed_at" => "2024-01-01T00:00:00Z" }
    ]

    active = repositories.select { |repository| OpenSourceUtils::MonitorSupport.active_repository?(repository, cutoff) }

    assert_equal %w[recent-push recent-update new-repository], active.map { |repository| repository["name"] }
  end

  def test_pagination_stops_without_fetching_another_page_after_cutoff
    pages = {
      1 => [
        { "created_at" => "2026-08-10T00:00:00Z", "id" => 1 },
        *Array.new(99) { |index| { "created_at" => "2025-01-01T00:00:00Z", "id" => index + 2 } }
      ],
      2 => [{ "created_at" => "2026-08-09T00:00:00Z", "id" => 3 }]
    }
    requested_pages = []
    fetcher = lambda do |path|
      page = path[/[?&]page=(\d+)/, 1].to_i
      requested_pages << page
      pages.fetch(page)
    end
    cutoff = Time.utc(2026, 8, 9)

    items = OpenSourceUtils::MonitorSupport.paged_array(
      "/repos/shakacode/example/pulls?state=all",
      fetcher: fetcher,
      stop_when: ->(item) { Time.parse(item.fetch("created_at")) < cutoff }
    )

    assert_equal [1], items.map { |item| item.fetch("id") }
    assert_equal [1], requested_pages
  end

  def test_request_budget_fails_closed_before_exceeding_limit
    budget = OpenSourceUtils::RequestBudget.new(2)

    2.times { budget.consume! }
    error = assert_raises(OpenSourceUtils::RequestBudgetExceeded) { budget.consume! }

    assert_equal 2, budget.used
    assert_match "2-request budget", error.message
  end

  def test_request_budget_rejects_an_unaffordable_scan_before_consuming_it
    budget = OpenSourceUtils::RequestBudget.new(3)
    budget.consume!

    error = assert_raises(OpenSourceUtils::RequestBudgetExceeded) { budget.ensure_capacity!(3) }

    assert_equal 1, budget.used
    assert_match "requires 3 more requests", error.message
  end

  def test_minimum_scan_requests_skips_discussion_cost_when_disabled
    repositories = [
      { "has_discussions" => false },
      { "has_discussions" => true }
    ]

    assert_equal 6, OpenSourceUtils::MonitorSupport.minimum_scan_requests(repositories)
  end

  def test_rate_limit_errors_are_not_retryable
    assert OpenSourceUtils::MonitorSupport.rate_limit_error?("API rate limit exceeded for user ID 1118459")
    assert OpenSourceUtils::MonitorSupport.rate_limit_error?("HTTP 429 Too Many Requests")
    refute OpenSourceUtils::MonitorSupport.rate_limit_error?("temporary network timeout")
  end
end
