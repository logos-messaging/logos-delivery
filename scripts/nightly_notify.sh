#!/usr/bin/env bash
# Reports the nightly CI result on Discord and in a tracking issue, only when it
# changes. The open `nightly-failure` issue is the state: it exists while the
# nightly is red.
#
#   red, no open issue    opens the issue, posts to Discord
#   red, open issue       comments on the issue, posts with the day count
#   green, open issue     posts, closes the issue
#   green, no open issue  nothing
#
# Re-running a failed report is safe: a run already recorded in the issue only
# posts again. A run older than the newest nightly that reported (success or
# failure) reports nothing, so a late or replayed run cannot overwrite newer state.
#
# Environment:
#   RESULT                   result of the nightly `ci` job (success, failure, cancelled, skipped)
#   GITHUB_REPOSITORY        owner/repo, set by Actions
#   GITHUB_RUN_ID            id of the nightly run, set by Actions
#   GH_TOKEN                 token with actions:read and issues:write
#   DISCORD_WEBHOOK_URL      optional; without it only the issue is updated
#   NIGHTLY_OWNER            optional; GitHub login the tracking issue is assigned to
set -euo pipefail

: "${RESULT:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_RUN_ID:?}"
repo=$GITHUB_REPOSITORY
run_url="https://github.com/$repo/actions/runs/$GITHUB_RUN_ID"
label=nightly-failure

case "$RESULT" in
  success | failure) ;;
  *)
    echo "nightly result is '$RESULT', nothing to report"
    exit 0
    ;;
esac

read -r workflow_id branch run_created < <(gh api "repos/$repo/actions/runs/$GITHUB_RUN_ID" \
  --jq '"\(.workflow_id) \(.head_branch) \(.created_at)"')
newer=$(gh api "repos/$repo/actions/workflows/$workflow_id/runs?branch=$branch&status=completed&per_page=20" \
  --jq '[.workflow_runs[] | select(.created_at > "'"$run_created"'") | select(.conclusion == "success" or .conclusion == "failure")] | length')
if [ "$newer" -gt 0 ]; then
  echo "a newer nightly has finished, it reports instead"
  exit 0
fi

# "<number> <createdAt>" of the open tracking issue, or empty.
issue=$(gh issue list -R "$repo" --label "$label" --state open --limit 1 \
  --json number,createdAt --jq '.[0] // empty | "\(.number) \(.createdAt)"')

issue_url() { echo "https://github.com/$repo/issues/$1"; }

# "true" when this run is already in the issue's body or comments, i.e. a re-run.
recorded() {
  gh issue view "$1" -R "$repo" --json body,comments \
    --jq '[.body, .comments[].body] | any(contains("'"$run_url"'"))'
}

# ci-required only summarises the other jobs, so it fails whenever one of them does.
failed_jobs() {
  gh api "repos/$repo/actions/runs/$GITHUB_RUN_ID/jobs" --paginate \
    --jq '.jobs[]
      | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "cancelled")
      | select(.name | endswith("ci-required") | not)
      | "- [\(.name)](\(.html_url)) \(.conclusion)"'
}

# post <title> <color> <description>
post() {
  if [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
    echo "::warning::DISCORD_WEBHOOK_URL is not set; skipping the Discord notification"
    return 0
  fi
  # Discord caps an embed description at 4096 characters.
  jq -n --arg title "$1" --argjson color "$2" \
    --arg desc "$3" --arg url "$run_url" \
    '{embeds: [{title: $title, color: $color, url: $url,
                description: (if ($desc | length) > 4000 then $desc[:4000] + "\n…" else $desc end)}]}' |
    curl -fsS --retry 3 --retry-all-errors -H "Content-Type: application/json" \
      -X POST --data-binary @- --config <(printf 'url = "%s"\n' "$DISCORD_WEBHOOK_URL")
}

red=15158332
green=3066993

if [ "$RESULT" = success ]; then
  if [ -z "$issue" ]; then
    echo "nightly is green and was green, nothing to report"
    exit 0
  fi
  read -r number _ <<<"$issue"
  # Post first: if the post fails, the issue stays open and a re-run posts again.
  post "✅ Nightly CI is green again" "$green" "Closing $(issue_url "$number")"
  gh issue close "$number" -R "$repo" --comment "Back to green: $run_url"
  exit 0
fi

failed=$(failed_jobs)
[ -n "$failed" ] || failed="(no failed job reported, see the run)"
report=$(printf '%s\n\nFailed jobs:\n%s\n' "$run_url" "$failed")

if [ -z "$issue" ]; then
  gh label create "$label" -R "$repo" --force --color B60205 \
    --description "The nightly CI run is failing"
  url=$(gh issue create -R "$repo" --title "Nightly CI is failing" \
    --label "$label" --label infra --body "The nightly CI run failed: $report")
  # Assigned separately: an owner that cannot be assigned must not cost the report.
  if [ -n "${NIGHTLY_OWNER:-}" ]; then
    gh issue edit "$url" -R "$repo" --add-assignee "$NIGHTLY_OWNER" ||
      echo "::warning::could not assign $url to $NIGHTLY_OWNER"
  fi
  post "❌ Nightly CI failed" "$red" "$(printf 'Failed jobs:\n%s\n\nTracking issue: %s' "$failed" "$url")"
  exit 0
fi

read -r number created <<<"$issue"
# Calendar days, so a run that starts a little early still counts as the next night.
days=$((($(date -u -d "${run_created%%T*}" +%s) - $(date -u -d "${created%%T*}" +%s)) / 86400 + 1))
already=$(recorded "$number")
if [ "$already" = true ]; then
  echo "run already recorded in $(issue_url "$number"), posting again only"
  title="❌ Nightly CI failed"
  if [ "$days" -gt 1 ]; then title="❌ Nightly CI still failing (day $days)"; fi
else
  gh issue comment "$number" -R "$repo" --body "Still failing, day $days: $report"
  title="❌ Nightly CI still failing (day $days)"
fi
post "$title" "$red" "$(printf 'Failed jobs:\n%s\n\nTracking issue: %s' "$failed" "$(issue_url "$number")")"
