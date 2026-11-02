# frozen_string_literal: true

require "time"

module OpenSourceUtils
  class RequestBudgetExceeded < StandardError; end

  class RequestBudget
    attr_reader :limit, :used

    def initialize(limit)
      @limit = Integer(limit)
      @used = 0
      raise ArgumentError, "request budget must be positive" unless @limit.positive?
    end

    def consume!
      raise RequestBudgetExceeded, "GitHub API #{@limit}-request budget exhausted" if @used >= @limit

      @used += 1
    end

    def ensure_capacity!(additional_requests)
      additional_requests = Integer(additional_requests)
      return if @used + additional_requests <= @limit

      raise RequestBudgetExceeded,
        "GitHub API scan requires #{additional_requests} more requests with #{@limit - @used} remaining in the #{@limit}-request budget"
    end
  end

  module MonitorSupport
    module_function

    def active_repository?(repository, cutoff)
      %w[created_at updated_at pushed_at].filter_map do |field|
        Time.parse(repository[field].to_s)
      rescue ArgumentError
        nil
      end.any? { |timestamp| timestamp >= cutoff }
    end

    def rate_limit_error?(message)
      message.to_s.match?(/(?:API rate limit (?:already )?exceeded|RATE_LIMITED|HTTP 429|secondary rate limit)/i)
    end

    def minimum_scan_requests(repositories)
      repositories.length * 2 + (repositories.length + 1) / 2 + repositories.count { |repository| repository["has_discussions"] }
    end

    def paged_array(path, fetcher:, stop_when: nil)
      page = 1
      items = []

      loop do
        separator = path.include?("?") ? "&" : "?"
        batch = fetcher.call("#{path}#{separator}per_page=100&page=#{page}")
        raise "Expected array from #{path}" unless batch.is_a?(Array)

        break if batch.empty?

        stopped = false
        batch.each do |item|
          if stop_when&.call(item)
            stopped = true
            break
          end
          items << item
        end

        break if stopped || batch.length < 100

        page += 1
      end

      items
    end
  end
end
