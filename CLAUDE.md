# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.


@AGENTS.md

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **logos-delivery** (13164 symbols, 22277 relationships, 275 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/logos-delivery/context` | Codebase overview, check index freshness |
| `gitnexus://repo/logos-delivery/clusters` | All functional areas |
| `gitnexus://repo/logos-delivery/processes` | All execution flows |
| `gitnexus://repo/logos-delivery/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |
| Work in the Kernel_api area (218 symbols) | `.claude/skills/generated/kernel-api/SKILL.md` |
| Work in the Persistency area (101 symbols) | `.claude/skills/generated/persistency/SKILL.md` |
| Work in the Api area (82 symbols) | `.claude/skills/generated/api/SKILL.md` |
| Work in the Waku_rln_relay area (74 symbols) | `.claude/skills/generated/waku-rln-relay/SKILL.md` |
| Work in the Waku_filter_v2 area (71 symbols) | `.claude/skills/generated/waku-filter-v2/SKILL.md` |
| Work in the Postgres_driver area (59 symbols) | `.claude/skills/generated/postgres-driver/SKILL.md` |
| Work in the Health_monitor area (53 symbols) | `.claude/skills/generated/health-monitor/SKILL.md` |
| Work in the Rln area (53 symbols) | `.claude/skills/generated/rln/SKILL.md` |
| Work in the Waku_enr area (52 symbols) | `.claude/skills/generated/waku-enr/SKILL.md` |
| Work in the Mobile area (52 symbols) | `.claude/skills/generated/mobile/SKILL.md` |
| Work in the Admin area (47 symbols) | `.claude/skills/generated/admin/SKILL.md` |
| Work in the Waku_store_sync area (47 symbols) | `.claude/skills/generated/waku-store-sync/SKILL.md` |
| Work in the Node area (46 symbols) | `.claude/skills/generated/node/SKILL.md` |
| Work in the Waku_store area (42 symbols) | `.claude/skills/generated/waku-store/SKILL.md` |
| Work in the Waku_keystore area (42 symbols) | `.claude/skills/generated/waku-keystore/SKILL.md` |
| Work in the Waku_core area (41 symbols) | `.claude/skills/generated/waku-core/SKILL.md` |
| Work in the Sqlite_driver area (40 symbols) | `.claude/skills/generated/sqlite-driver/SKILL.md` |
| Work in the Databases area (38 symbols) | `.claude/skills/generated/databases/SKILL.md` |
| Work in the Conf_builder area (36 symbols) | `.claude/skills/generated/conf-builder/SKILL.md` |
| Work in the Filter area (36 symbols) | `.claude/skills/generated/filter/SKILL.md` |

<!-- gitnexus:end -->
