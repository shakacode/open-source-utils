# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
load File.expand_path("../bin/monitor_outside_activity", __dir__)

class MonitorRegressionTest < Minitest::Test
  def setup
    @runner = Object.new
    @cutoff = Time.utc(2026, 11, 1)
  end

  def test_old_internal_pr_and_later_pages_still_collect_new_outside_reviews
    queries = []
    pages = [
      { "nodes" => [pr(1, "APPROVED")], "pageInfo" => { "hasNextPage" => true, "endCursor" => "next" } },
      { "nodes" => [pr(2, "CHANGES_REQUESTED")], "pageInfo" => { "hasNextPage" => false } }
    ]
    @runner.define_singleton_method(:graphql_query) do |query|
      queries << query
      { "data" => { "repository" => { "pullRequests" => pages.shift } } }
    end
    items = []
    @runner.send(:collect_pull_requests, "shakacode", "example", "shakacode/example", @cutoff, Set["maintainer"], Set.new, items)
    assert_equal ["new pull request review", "requested changes"], items.map { |item| item[:activity_type] }
    assert_equal %w[outside outside], items.map { |item| item[:author] }
    assert_equal ["pull_review:review1", "pull_review:review2"], items.map { |item| item[:id] }
    assert_includes queries.last, 'after: "next"'
  end

  def test_large_review_connection_is_paginated_in_batches
    first = pr(1, "APPROVED")
    first["reviews"]["pageInfo"] = { "hasNextPage" => true, "endCursor" => "more" }
    next_reviews = pr(2, "CHANGES_REQUESTED")["reviews"]
    queries = []
    @runner.define_singleton_method(:graphql_query) do |query|
      queries << query
      if queries.length == 1
        { "data" => { "repository" => { "pullRequests" => { "nodes" => [first], "pageInfo" => {} } } } }
      else
        { "data" => { "pr0" => { "reviews" => next_reviews } } }
      end
    end
    items = []
    @runner.send(:collect_pull_requests, "shakacode", "example", "shakacode/example", @cutoff, Set.new, Set.new, items)
    assert_equal 2, items.length
    assert_includes queries.last, 'after:"more"'
  end

  def test_fallbacks_propagate_rate_limit_and_budget_errors
    [RuntimeError.new("HTTP 429"), OpenSourceUtils::RequestBudgetExceeded.new("exhausted")].each do |error|
      calls = 0
      @runner.define_singleton_method(:gh_json) { |*_args| calls += 1; raise error }
      @runner.define_singleton_method(:graphql_query) { |*_args| calls += 1; raise error }
      %i[fetch_team_members fetch_trusted_actors_graphql fetch_trusted_actors_rest fetch_trusted_actors_raw].each do |method|
        assert_same error, assert_raises(error.class) { @runner.send(method) }
      end
      assert_equal 4, calls
    end
  end

  def test_unrelated_metadata_does_not_grant_trust
    @runner.define_singleton_method(:fetch_trusted_actors_graphql) { "trusted_users: [Maintainer]\nnotes: outsider\n" }
    assert_equal ["maintainer"], @runner.send(:fetch_trusted_actors)[:trusted]
  end

  def test_yaml_objects_are_rejected
    @runner.define_singleton_method(:fetch_trusted_actors_graphql) { "--- !ruby/object:Object {}" }
    assert_raises(Psych::DisallowedClass) { @runner.send(:fetch_trusted_actors) }
  end

  def test_deleted_actor_and_graphql_escaping
    refute @runner.send(:outside_actor?, nil, Set.new)
    value = "a\\b\"c\n"
    assert_equal value, JSON.parse('"' + @runner.send(:gq, value) + '"')
  end

  def test_discussion_pagination_stops_at_cutoff
    calls = 0
    @runner.define_singleton_method(:graphql_query) do |_query|
      calls += 1
      raise "unnecessary request" if calls > 1
      { "data" => { "repository" => { "hasDiscussionsEnabled" => true, "discussions" => {
        "nodes" => [{ "updatedAt" => "2020-01-01T00:00:00Z" }], "pageInfo" => { "hasNextPage" => true }
      } } } }
    end
    @runner.send(:collect_discussions, "shakacode", "example", @cutoff, Set.new, Set.new, [])
    assert_equal 1, calls
  end

  def test_filtered_run_does_not_advance_shared_watermark_or_send_slack
    Dir.mktmpdir do |dir|
      state = { "last_successful_run_at" => "2026-10-01T00:00:00Z" }
      writes = []
      @runner.define_singleton_method(:read_state) { state }
      @runner.define_singleton_method(:fetch_team_members) { [] }
      @runner.define_singleton_method(:fetch_trusted_actors) { { trusted: [], counts: {} } }
      @runner.define_singleton_method(:paged_array) { |*_args| [] }
      @runner.define_singleton_method(:safe_write) { |path, payload| writes << [path, payload] }
      @runner.define_singleton_method(:post_slack) { |*_args| raise "must not send" }
      previous = ENV["MONITOR_REPO"]
      begin
        ENV["MONITOR_REPO"] = "shakacode/does-not-exist "
        assert_raises(SystemExit) { capture_io { @runner.send(:run) } }
        assert_equal [RESULT_PATH], writes.map(&:first)
        refute writes.last.last[:state_updated]
        assert_equal "2026-10-01T00:00:00Z", state["last_successful_run_at"]
      ensure
        ENV["MONITOR_REPO"] = previous
      end
    end
  end

  def test_slack_webhook_uses_mrkdwn_and_escapes_title
    item = { summary: "Review <code> | label", repository: "shakacode/example", activity_type: "review", link: "https://github.com/shakacode/example/pull/1", author: "outside" }
    message = @runner.send(:build_activity_message, [item], @cutoff, @cutoff)
    assert_includes message, '*Outside GitHub activity detected*'
    assert_includes message, '<https://github.com/shakacode/example/pull/1|Review &lt;code&gt; ¦ label>'
  end

  private

  def pr(number, state)
    { "id" => "pr#{number}", "number" => number, "title" => "Old PR", "createdAt" => "2020-01-01T00:00:00Z",
      "author" => { "login" => "maintainer", "__typename" => "User" },
      "reviews" => { "nodes" => [{ "id" => "review#{number}", "state" => state,
        "submittedAt" => "2026-11-01T00:00:01Z", "url" => "https://github.com/shakacode/example/pull/#{number}#review",
        "author" => { "login" => "outside", "__typename" => "User" } }], "pageInfo" => { "hasPreviousPage" => false } } }
  end
end


class MonitorRegressionTest
  def test_raw_request_consumes_budget
    @runner.define_singleton_method(:gh_json) { |*_args| { "download_url" => "https://raw.githubusercontent.com/shakacode/example/main/actors.yml" } }
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.body = "trusted_users: [maintainer]"
    before = REQUEST_BUDGET.used
    original = Net::HTTP.method(:get_response)
    Net::HTTP.define_singleton_method(:get_response) { |_uri| response }
    begin
      assert_equal "trusted_users: [maintainer]", @runner.send(:fetch_trusted_actors_raw)
      assert_equal before + 1, REQUEST_BUDGET.used
    ensure
      Net::HTTP.define_singleton_method(:get_response, original)
    end
  end
end

class MonitorRegressionTest
  def test_replies_on_old_internal_comments_are_collected_and_paginated
    actor = { "login" => "outside", "__typename" => "User" }
    reply = { "id" => "reply1", "url" => "https://github.com/discussion#reply1", "createdAt" => @cutoff.iso8601, "author" => actor }
    comment = { "id" => "root", "createdAt" => "2020-01-01T00:00:00Z", "author" => { "login" => "maintainer" },
      "replies" => { "nodes" => [reply], "pageInfo" => { "hasNextPage" => true, "endCursor" => "next" } } }
    @runner.define_singleton_method(:graphql_query) do |_query|
      { "data" => { "node" => { "replies" => { "nodes" => [reply.merge("id" => "reply2")], "pageInfo" => {} } } } }
    end
    items = []
    @runner.send(:collect_discussion_comment, "shakacode", "example", 1, "Discussion", comment, @cutoff, Set["maintainer"], Set.new, items)
    assert_equal %w[discussion_comment:reply1 discussion_comment:reply2], items.map { |item| item[:id] }
  end

  def test_humans_named_like_bots_are_not_suppressed
    @runner.define_singleton_method(:fetch_trusted_actors_graphql) { "trusted_bots: [claude]\ntrusted_metadata_bots: [github-actions]\ntrusted_teams: [shakacode]\ntrusted_users: [maintainer]\n" }
    trusted = @runner.send(:fetch_trusted_actors)[:trusted].to_set
    assert @runner.send(:outside_actor?, { "login" => "claude", "type" => "User" }, trusted)
    assert @runner.send(:outside_actor?, { "login" => "shakacode", "type" => "User" }, trusted)
    refute @runner.send(:outside_actor?, { "login" => "claude", "type" => "Bot" }, trusted)
  end
end

class MonitorRegressionTest
  def test_successful_dry_run_with_activity_does_not_send_or_advance_state
    writes = []
    sends = []
    @runner.define_singleton_method(:read_state) { { "last_successful_run_at" => "2026-10-31T00:00:00Z" } }
    @runner.define_singleton_method(:fetch_team_members) { |*_args| [] }
    @runner.define_singleton_method(:fetch_trusted_actors) { { trusted: [], counts: {} } }
    @runner.define_singleton_method(:paged_array) do |*_args|
      [{ "name" => "example", "full_name" => "shakacode/example", "pushed_at" => Time.now.utc.iso8601 }]
    end
    @runner.define_singleton_method(:collect_issues) do |*_args|
      _args.last << { repository: "shakacode/example", activity_type: "new issue", author: "outside", summary: "issue" }
    end
    %i[collect_issue_comments collect_pull_requests collect_pull_review_comments].each do |method|
      @runner.define_singleton_method(method) { |*_args| nil }
    end
    @runner.define_singleton_method(:safe_write) { |path, data| writes << [path, data] }
    @runner.define_singleton_method(:post_slack) { |text| sends << text; true }
    previous = ENV["MONITOR_DRY_RUN"]
    begin
      ENV["MONITOR_DRY_RUN"] = "1"
      error = assert_raises(SystemExit) { capture_io { @runner.send(:run) } }
      assert_equal 0, error.status
      assert_empty sends
      assert_equal [RESULT_PATH], writes.map(&:first)
      refute writes.last.last[:state_updated]
      assert_equal 1, writes.last.last[:outside_activity_count]
      assert_equal "completed", writes.last.last[:result_status]
    ensure
      ENV["MONITOR_DRY_RUN"] = previous
    end
  end
end
