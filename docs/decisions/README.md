# Architecture Decision Records (ADR)

An Architecture Decision Record (ADR) captures an important architecture decision along with its context, rationale, and alternatives. See `.claude/skills/adr-skill/` for how to write one.

## Conventions

- Directory: `docs/decisions/`
- Naming: `YYYY-MM-DD-verb-phrase.md`
- Format: Context and Problem Statement, Decision, Alternatives Considered, and optional More Information
- Omit YAML frontmatter and explicit status fields; merging the ADR pull request accepts the decision
- Include tradeoffs in the decision and alternatives; keep implementation and verification in issues or PRs

## Workflow

- Propose a new ADR in a pull request and discuss it there.
- Merging the pull request accepts the decision; an explicit status is unnecessary.
- If replaced later: create a new ADR and link both records, explaining the replacement.

## ADRs

- 2026-11-24 — [Let callers build liblogosdelivery with plain `nim c`](2026-11-24-let-callers-build-liblogosdelivery-with-plain-nim-c.md)
