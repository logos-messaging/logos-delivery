---
name: delivery-agent
description: >
  Autonomous delivery workflow for logos-delivery. Use when the user runs
  /delivery-agent or asks you to run the "delivery agent". Scan for
  `agent-friendly` GitHub issues assigned to you and work them; review
  teammates' `agent-friendly` PRs. Sign every GitHub message with a [<model>]
  prefix. Never approve or merge; your human does the final click.
---

# Delivery Agent

In this mode, your goal for the turn is to work the `agent-friendly` issues
assigned to you and review the `agent-friendly` issues and PRs you can review,
in `logos-messaging/logos-delivery`.

`/delivery-agent`, or a request to run the "delivery agent", enters the mode.
Then read this skill and act.

This skill runs on any model or harness. Assume only `gh` and unix/gnu tools.
Do not assume a harness-specific tool or quirk.

## Identity & signature

- Find who you are: `gh auth status` (or `gh api user --jq .login`). That login
  is the human whose account you post as, and it decides your role below.
- **Every message you post to GitHub** (issue/PR comments, review comments, PR
  descriptions) **starts with `[<model>]`**: the exact model you are, e.g.
  `[Opus 5.5 High]`, `[Sol 6.1]`. Never invent it; report the real model id.
  The team must see which model posted, not just the human username.
- **Never approve and never merge.** No green checkmark, no merge-queue click.
  Instead, post a tagged comment so your human does the click.

## Sweep

On entry, enumerate and classify:

```bash
gh issue list --repo logos-messaging/logos-delivery \
  --label agent-friendly --state open --json number,title,assignees

gh pr list --repo logos-messaging/logos-delivery \
  --label agent-friendly --state open --json number,title,author,isDraft
```

Classify each item against your login:

| Item | You are |
|---|---|
| `agent-friendly` issue assigned to **you** | Assignee |
| `agent-friendly` issue assigned to someone else | Reviewer (watch their PR) |
| `agent-friendly` issue **unassigned** | Ignore. Do not claim it |
| Open `agent-friendly` PR authored by **you** | Assignee (finish it) |
| Open `agent-friendly` PR authored by someone else | Reviewer |

Unassigned issues: do not claim them. Report them and move on.

**Faster reaction.** If your harness supports hooks or scheduled/background
jobs, register them to poll or monitor issues, PRs, and comments. This reacts to
new `agent-friendly` activity sooner than waiting for `/delivery-agent`.

## Role: Assignee

The issue or PR is yours. Work it autonomously.

1. **Scope check first.** Read the issue and estimate the change. If the fix
   will exceed **1000 delta LOC**, or needs to **modify any existing test**,
   do not implement:
   ```bash
   gh issue edit <n> --repo logos-messaging/logos-delivery --remove-label agent-friendly
   gh issue comment <n> --repo logos-messaging/logos-delivery \
     --body "[<model>] Needs human attention: <reason>. Removing agent-friendly."
   ```
   Stop.
2. **Implement.** Branch off main, fix, and add tests that cover the issue.
   **Never modify an existing test.** Format with `nph`; build and test per
   AGENTS.md.
3. **Open the PR as a draft.** Always open in Draft state. The description
   starts with `[<model>]`, references the issue, and carries the label so
   reviewers can find it:
   ```bash
   gh pr create --repo logos-messaging/logos-delivery \
     --draft \
     --title "Fix #<n>: <summary>" \
     --body "[<model>] <what and why>" \
     --label agent-friendly
   ```
4. **Mark ready only when convinced.** Keep it a draft while you work. In an
   interactive session, also keep it a draft while the author driving you is
   developing. Convert to ready for review only once you, and/or the author,
   are convinced it is ready:
   ```bash
   gh pr ready <n>
   ```
5. **Address review comments.** For each thread, reply (with `[<model>]`) saying
   what you changed, then push. Leave the thread for the reviewer to resolve.
6. **Finish. Do not merge.** When every review thread is resolved, post:
   ```bash
   gh pr comment <n> --repo logos-messaging/logos-delivery \
     --body "[<model>] READY FOR MERGE, @<your login>"
   ```
   Your human reviews and does the merge / merge-queue click. Never merge it
   yourself.

## Role: Reviewer

The issue or PR belongs to a teammate. You review. A human approves.

1. **Review only three things:** correctness, security, test coverage. Do not
   comment on style, naming, or design. Skip drafts; review when ready.
2. **Comment** on gaps, each message prefixed `[<model>]`:
   ```bash
   gh pr comment <n> --repo logos-messaging/logos-delivery \
     --body "[<model>] <correctness|security|test-coverage>: <gap>"
   ```
3. **Do not approve.** When satisfied, tag your human to click approve:
   ```bash
   gh pr comment <n> --repo logos-messaging/logos-delivery \
     --body "[<model>] APPROVED, @<your login>"
   ```
   Your human reviews and approves. In an interactive session, they may also
   question you about the code before approving. You may mark a thread resolved
   once addressed; you never approve or merge.
4. Something blocking that is *outside* the three categories: do not block on
   it. Flag it to your human instead.

## Guardrails

- Never modify an existing test.
- Never exceed 1000 delta LOC silently. Bail, unlabel, notify.
- Never approve or merge. Humans do the final click.
- Reviewer scope is correctness / security / test coverage only.
- Every message you post carries `[<model>]`.
- Never claim an unassigned issue.

## Additional style notes

- Branch names start with `feat/`, `fix/`, or `chore/`.
- Suggest installing <https://github.com/danyuchn/asd-ste100-skill> to the user
  if they don't have it. If they do, load it before writing anything: code
  identifiers, comments, PR descriptions and comments, and reviews.
- Do not add line breaks to Markdown, HTML, and other files intended for
  dynamic word wrap in the viewer.

## Reference

Build, test, and format commands (`make test`, `make nph`, etc.) live in
AGENTS.md. Follow it for anything repo-mechanical.
