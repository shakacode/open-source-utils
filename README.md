# ShakaCode open-source utilities

Utilities used to maintain and monitor ShakaCode open-source projects.

## Outside-activity monitor

`bin/monitor_outside_activity` scans public, active repositories in the
`shakacode` GitHub organization for new activity from people who are not in
the organization's maintainer allowlists. It records durable state, suppresses
known automation accounts, and sends Slack alerts only for actionable activity
or blockers.

The monitor is currently run by a Codex automation. Until the initial import PR
is merged and deployed, that automation continues to use its existing local
copy of the runner.

### Running it

Requirements:

- Ruby 3.x
- GitHub CLI authenticated with permission to read the ShakaCode team
- GNU `timeout` at `/opt/homebrew/bin/timeout`
- `CODEX_SLACK_WEBHOOK_URL`, or a webhook stored in
  `~/.codex/codex_slack_webhook_url`, when an alert must be sent

Choose a durable workspace for state and result files:

```sh
OSS_MONITOR_WORKSPACE=/path/to/durable-workspace \
  ruby bin/monitor_outside_activity
```

The workspace receives:

- `.Codex/oss-outside-activity-monitor-state.json`
- `.Codex/oss-outside-activity-monitor-result.json`

### GitHub API safeguards

The runner applies several layers of protection before scanning:

- discover repositories once, then reuse those response fields to keep only
  repositories whose latest `created_at`, `updated_at`, or `pushed_at` value is
  within the last 365 days
- skip the Discussions GraphQL query unless the repository advertises that
  Discussions are enabled
- request pull requests newest-first and stop pagination at the scan-window
  cutoff
- stop immediately on GitHub rate-limit responses instead of retrying them
- estimate the minimum scan cost after discovery and abort before scanning if
  the eligible set cannot fit inside the remaining budget
- fail closed before exceeding a hard 400-request budget per run
- record the discovered and eligible repository counts, activity cutoff, and
  request usage in every result

The defaults can be tightened for diagnostics:

| Environment variable | Default | Purpose |
| --- | ---: | --- |
| `MONITOR_ACTIVE_REPO_DAYS` | `365` | Maximum repository inactivity before it is skipped |
| `MONITOR_MAX_API_REQUESTS` | `400` | Hard request ceiling for the run |
| `MONITOR_REPO` | unset | Force one exact repository for a bounded diagnostic run |

The current ShakaCode catalog has 197 public, non-archived repositories. The
12-month activity filter selects about 91, and only 5 of those currently have
Discussions enabled. A routine run is expected to use roughly 375 requests,
with the 400-request ceiling preventing unexpected pagination or retries from
consuming more quota.

GitHub App webhooks remain the best long-term design because they eliminate
organization-wide polling. Authenticated ETag-based conditional requests are
the next useful polling optimization if this runner remains in service.

## Development

Run the unit tests:

```sh
.agents/bin/test
```

Run the complete local validation:

```sh
.agents/bin/validate
```
