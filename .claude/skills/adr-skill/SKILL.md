---
name: adr-skill
description: Create, update, or consult Architecture Decision Records (ADRs) in docs/decisions/. Use when capturing an architecture decision and its rationale, maintaining its lifecycle, checking decisions that govern planned changes, or when a session leads to a new decision affecting future work across modules, repositories or consumers. Do not use for routine bug fixes or changes confined to one protocol's internals.
---

# ADR Skill

Adapted from [vercel/ai `skills/adr-skill`](https://github.com/vercel/ai/tree/7aae3c3a809765413613249c76b521eaa52ef3af/skills/adr-skill) (Apache-2.0).

An ADR records what we decided and why. Keep it concise and self-contained so future contributors and coding agents can understand the decision without the original conversation. Implementation plans and verification belong in issues and pull requests.

## When to Write an ADR

Write an ADR for decisions that change how the system is built or operated, have meaningful alternatives, and affect future work: architecture patterns, dependencies, build and release, the C API contract, or protocol design.

Routine implementation choices, bug fixes, and style preferences usually do not need an ADR. If a decision is already covered, update or reference the existing record.

When an architectural choice comes up during implementation, propose capturing it if its rationale would help future contributors. If the user did not explicitly ask you to write an ADR, confirm with them first before writing or editing one. Respect the user's requested scope.

## Create an ADR

### Gather Context

1. Read the ADR index at `docs/decisions/README.md`.
2. Read relevant ADRs and inspect related code, dependencies, and constraints.
3. Use the supplied discussion or request to identify the problem, chosen option, alternatives, tradeoffs, and non-goals. Ask focused questions only for material gaps; do not repeat questions already answered by the source.
4. Check every claim against merged code and pull requests, not against PR descriptions alone: descriptions go stale when a PR changes during review.
5. If a choice would contradict an existing ADR, discuss the conflict with the human before implementing it. An explicit request to change that decision provides the intent for updating the record.

### Draft

Copy [assets/templates/adr-simple.md](assets/templates/adr-simple.md) to `docs/decisions/NNNN-verb-phrase.md`, using the next free number in the index (check open pull requests too), fill or remove every placeholder, and add the record to the index. Alternatives can be short bullets or use option headings when they need more explanation; both fit the same template.

- **Context and Problem Statement**: the problem, trigger, and relevant constraints.
- **Decision**: what is chosen, why, scope, non-goals, and accepted tradeoffs.
- **Alternatives Considered**: the benefits and drawbacks of other options and why they were rejected. Avoid repeating the same tradeoffs in multiple sections.
- **More Information** (optional): related records, PRs, issues, references, and revisit conditions.

Do not add YAML frontmatter, a separate Consequences section, an Implementation Plan, or Verification checklists. Do not add explicit status fields; merging the ADR pull request accepts the decision. The creation date belongs in the index; participants can be credited in the linked discussion or pull request.

### Review

Use [references/review-checklist.md](references/review-checklist.md). Check that the rationale, alternatives, scope, and accepted costs are clear. Report material gaps and fix what can be resolved from the available evidence. Do not inflate the record to satisfy a template.

See [references/examples.md](references/examples.md) for a filled-out example and [references/adr-conventions.md](references/adr-conventions.md) for naming and lifecycle details.

## Consult Existing ADRs

Before changing architecture, scan the index and read relevant ADRs fully. Follow their decisions and constraints. Check for ADR references in code when a pattern's rationale is unclear.

If implementation differs from a decision, flag the discrepancy. Do not silently replace an accepted decision with a different choice. Reference the governing ADR in the implementation PR, and add a lightweight code comment at a key entry point when it helps discoverability:

```nim
# ADR: docs/decisions/0007-choose-a-storage-engine.md
```

ADRs can link to the implementation PR or key code entry points in More Information without duplicating a file-by-file implementation plan.

## Update an Existing ADR

- **Deprecate**: explain why the decision no longer applies in More Information.
- **Supersede**: create a replacement ADR and link both records.
- **Add learnings**: append a dated note in More Information. Preserve the original rationale.
- **Simplify formatting**: preserve the decision and relevant reasoning; move tradeoffs into Decision or Alternatives Considered and leave implementation and verification detail in linked PRs or issues.

Update the index entry as well. Track implementation work in issues or PRs, link back to the ADR, and add later learnings when they affect the rationale or revisit conditions.
