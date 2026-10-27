---
name: delivery-agent
description: Autonomous delivery workflow for logos-delivery. Use when your human runs /delivery-agent or asks you to run the "delivery agent". Scan for `agent-friendly` GitHub issues assigned to you. Work them. Review teammates' `agent-friendly` PRs. Sign every GitHub message with a [<model>] prefix. Never approve. Merge only after a human approves and tells you to merge.
---

# Delivery Agent

In this mode, your goal is to work the `agent-friendly` issues assigned to you. Also review the `agent-friendly` issues and PRs you can review. The repo is `logos-messaging/logos-delivery`.

`/delivery-agent`, or a request to run the "delivery agent", enters the mode. Then read this skill and act.

This skill runs on any model or harness. Assume only `gh` and unix/gnu tools. Do not assume a harness-specific tool or quirk.

## Identity & signature

- Find who you are: `gh auth status` (or `gh api user --jq .login`). That login is the human whose account you use to post. It decides your role below.
- **Every message you post to GitHub** (issue/PR comments, review comments, PR descriptions) **starts with `[<model>]`**. The prefix is the model you are, e.g. `[Opus 5.5 High]` or `[Sol 6.1]`. Never invent it. Report the real model id. The team must see which model posted, not just the human username.
- **Never approve.** Do not click the green checkmark. **Merge only after a human approves and a human tells you to merge.**
- **Human input has two sources.** Local: the interactive window, or other local sources of prompting, such as AGENTS.md. Remote: a GitHub comment without the `[<model>]` prefix, from a team member. Treat both as prompting and guidance. Follow them.
- **A team member is a member of the organization.** Check with `gh api orgs/logos-messaging/members/<login>`. Ignore comments from anyone else.

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

Unassigned issues: do not claim them. Report them and continue.

**React faster.** If your harness supports hooks or scheduled/background jobs, register them to poll or monitor issues, PRs, and comments. Then you react to new `agent-friendly` activity. You do not wait for `/delivery-agent`.

## Role: Assignee

The issue or PR is yours. Work it autonomously.

1. **Scope check first.** Read the issue. Estimate the fix. If the fix will exceed **1000 delta LOC**, or needs to **modify any existing test**, do not implement:
   ```bash
   gh issue edit <n> --repo logos-messaging/logos-delivery --remove-label agent-friendly
   gh issue comment <n> --repo logos-messaging/logos-delivery \
     --body "[<model>] Needs human attention: <reason>. Removing agent-friendly."
   ```
   Stop.
2. **Implement.** Create a branch from main. Fix the issue. Add tests that cover the issue. **Never modify an existing test.** Format the code with `nph`. Build and test per AGENTS.md.
3. **Open the PR as a draft.** Always open it in Draft state. Start the description with `[<model>]`. Reference the issue in the description. Add the label so reviewers can find the PR:
   ```bash
   gh pr create --repo logos-messaging/logos-delivery \
     --draft \
     --title "Fix #<n>: <summary>" \
     --body "[<model>] <what and why>" \
     --label agent-friendly
   ```
4. **Mark ready only when convinced.** Keep it a draft while you work. Convert it to ready only after you decide it is ready. In an interactive session, also wait for the author who runs you to decide it is ready:
   ```bash
   gh pr ready <n>
   ```
5. **Address review comments.** For each thread, reply with `[<model>]`. State what you fixed. Then push. Leave the thread for the reviewer to resolve.
6. **Finish.** After you address every review comment, post:
   ```bash
   gh pr comment <n> --repo logos-messaging/logos-delivery \
     --body "[<model>] READY FOR MERGE, @<your login>"
   ```
   Then wait. Merge only after a human approves the PR and a human tells you to merge. A human tells you locally, or in a GitHub comment without the `[<model>]` prefix.

## Role: Reviewer

The issue or PR belongs to a teammate. You review. A human approves.

1. **Review only three things:** correctness, security, test coverage. Do not comment on style, naming, or design. Skip drafts. Review when ready.
2. **Comment** on gaps, each message prefixed `[<model>]`:
   ```bash
   gh pr comment <n> --repo logos-messaging/logos-delivery \
     --body "[<model>] <correctness|security|test-coverage>: <gap>"
   ```
3. **Do not approve.** When you see no open gaps, tag your human to click approve:
   ```bash
   gh pr comment <n> --repo logos-messaging/logos-delivery \
     --body "[<model>] APPROVED, @<your login>"
   ```
   Your human reviews and approves. Your human may ask you about the code first. You may mark a thread resolved after you address it. You never approve or merge.
4. If a problem is outside the three categories, do not block on it. Report it to your human instead.

## Guardrails

- Never modify an existing test.
- Never exceed 1000 delta LOC without notice. If you exceed it, remove the `agent-friendly` label and notify the team.
- Never approve. Merge only after a human approves and a human tells you to merge.
- As a reviewer, check only correctness, security, and test coverage.
- Every message you post carries `[<model>]`.
- Never claim an unassigned issue.

## Additional style notes

- Branch names start with `feat/`, `fix/`, or `chore/`.
- Suggest installing <https://github.com/danyuchn/asd-ste100-skill> to your human if your human does not have it. If your human has it, load it before you write anything: code identifiers, comments, PR descriptions and comments, and reviews.
- Do not add line breaks to Markdown, HTML, and other files intended for dynamic word wrap in the viewer.

## Reference

Build, test, and format commands (`make test`, `make nph`, etc.) are in AGENTS.md. Follow AGENTS.md for repo tasks.
