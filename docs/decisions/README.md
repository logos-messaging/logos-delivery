# Architecture Decision Records (ADR)

An Architecture Decision Record (ADR) captures an important architecture decision along with its context, rationale, and alternatives. See `.claude/skills/adr-skill/` for how to write one.

## Conventions

- Directory: `docs/decisions/`
- Naming: `NNNN-verb-phrase.md`, the next free four-digit number, headed `# ADR-NNNN: Title`; numbers are never reused
- Index entry: `- NNNN — [Title](NNNN-verb-phrase.md) — YYYY-MM-DD`, the date the record was created, followed by `— superseded by NNNN` or `— deprecated` when that applies
- Format: Context and Problem Statement, Decision, Alternatives Considered, and optional More Information
- Omit YAML frontmatter and explicit status fields; merging the ADR pull request accepts the decision
- Include tradeoffs in the decision and alternatives; keep implementation and verification in issues or PRs

## Workflow

- Propose a new ADR in a pull request and discuss it there.
- Merging the pull request accepts the decision; an explicit status is unnecessary.
- If replaced later: create a new ADR and link both records, explaining the replacement.

## ADRs

- 0001 — [Let callers build liblogosdelivery with plain `nim c`](0001-let-callers-build-liblogosdelivery-with-plain-nim-c.md) — 2026-11-24

