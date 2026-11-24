# ADR Conventions (Reference)

## Directory

Store ADRs in `docs/decisions/` and keep its `README.md` index current.

## Filename Conventions

Pattern: `NNNN-title-with-dashes.md`, headed `# ADR-NNNN: Title`.

- `NNNN` is the next free four-digit number in the index; never reuse or renumber one, even for a superseded record.
- Title uses lowercase, dashes, present-tense imperative verb phrase.
- Examples: `0001-choose-database.md`, `0002-adopt-adrs.md`
- Check open pull requests for a number already taken before opening yours.

## Sections

Use Context and Problem Statement, Decision, and Alternatives Considered. More Information is optional. Include accepted tradeoffs in Decision and option-specific tradeoffs with the alternatives. Do not repeat them in a separate Consequences section.

Keep implementation plans and verification in issues and pull requests, linked from the ADR when useful. Do not add YAML frontmatter.

## Acceptance

An ADR is accepted when its pull request merges, therefore an explicit status on the ADR is unnecessary.

Do not add explicit status fields to ADRs; an index entry only gains `— superseded by NNNN` or `— deprecated`. Keep the creation date in the index. If a decision is deprecated or superseded, explain why in More Information and link any replacement in both directions.

## Mutability

- Prefer appending new information with a date stamp over rewriting existing content.
- If a decision is replaced, create a new ADR and explicitly supersede the old one.
- After-action notes are fine to edit in place.

## Categories (Large Projects)

For repos accumulating many ADRs, use subdirectories:

```
docs/decisions/
  backend/
    0001-use-postgres.md
  frontend/
    0002-use-react.md
  infrastructure/
    0003-use-terraform.md
```

Numbers stay global across categories, so every `ADR-NNNN` and index entry stays unique. Choose a categorization scheme early (by architectural layer, by domain, by team) and document it in the index.

Alternative: use tags or a flat structure with a searchable index. Subdirectories are simpler and work with all tools.
