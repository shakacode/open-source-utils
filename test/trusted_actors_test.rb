# frozen_string_literal: true

require "minitest/autorun"
load File.expand_path("../bin/monitor_outside_activity", __dir__)

class TrustedActorsTest < Minitest::Test
  def setup
    @runner = Object.new
  end

  def test_reads_relocated_allowlist_from_graphql
    query = nil
    @runner.define_singleton_method(:graphql_query) do |value|
      query = value
      { "data" => { "repository" => { "object" => { "text" => "trusted_users:\n  - ExampleUser\n" } } } }
    end

    result = @runner.send(:fetch_trusted_actors)

    assert_includes query, "main:.agents/shaka/trusted-github-actors.yml"
    assert_includes result[:trusted], "exampleuser"
    assert_equal 1, result[:counts][:users]
  end

  def test_missing_sources_fail_closed_with_source_in_error
    %i[fetch_trusted_actors_graphql fetch_trusted_actors_rest fetch_trusted_actors_raw].each do |method|
      @runner.define_singleton_method(method) { nil }
    end

    error = assert_raises(RuntimeError) { @runner.send(:fetch_trusted_actors) }

    assert_includes error.message, "shakacode/react_on_rails/.agents/shaka/trusted-github-actors.yml"
    assert_includes error.message, "unavailable or empty"
  end
end
