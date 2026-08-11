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

### GitHub API usage

The imported runner preserves the existing behavior so it can be moved under
version control without changing production semantics. It currently polls each
public, non-archived ShakaCode repository and is not considered rate-limit
optimized.

Known follow-up work:

- replace organization-wide polling with GitHub App webhooks
- stop pull-request pagination as soon as the requested time window is passed
- persist ETags and use authenticated conditional requests
- honor GitHub rate-limit reset headers instead of retrying quota failures
- cache repository and allowlist metadata when safe

Until that work is complete, the Codex automation should run no more than
weekly.
