# Phase 1 adoption spikes

SPEC.md §5's first step: before writing a parser, evaluate the existing
Mojo libraries. Both spikes ran on primo on 2026-10-17 against the
proven pin (pixi 0.81.0, channel `https://conda.modular.com/max`,
`mojo ==1.1.0`; `mojo --version` → Mojo 1.1.0 (8189361e)).

## Markdown — conorbronsdon/mojo-markdown

- **Repo:** https://github.com/conorbronsdon/mojo-markdown
- **Commit:** `11a1963db7bbf25fd20dca5796c98269efda8538` (v0.2.0,
  "Migrate to released Mojo 1.0")
- **License:** MIT
- **Builds on the pin:** yes; its own unit suites pass (49/49, 20/20).
- **Frozen-corpus run:** its conformance runner (exact byte match)
  against the frozen CommonMark 0.31.2 corpus (652 examples) scored
  **643/652 = 98.62%**. The extraction was independently verified:
  records extracted from the frozen `corpus/spec.txt` are byte-identical
  to the project's own case file.
- **Failures (9), every one classified:**
  - Examples 1, 2, 3 — literal tab characters are not expanded to tab
    stops; example 13 (backslash before a tab) is the same root cause.
  - Example 25 — the named-entity table is incomplete.
  - Examples 93, 312 — container laziness / list-marker column rules.
  - Examples 206, 540 — link labels are not matched under Unicode case
    folding ([ΑΓΩ]/[αγω], [ẞ]/[SS]).
  - These match the limitations the upstream README itself documents.
- **Adoption bar (SPEC.md §5):** ≥99% (≥646/652) with every failure
  understood and named. The failures are understood; the count is 9.
- **Verdict: REJECT as-is.** A vendored delta is the recorded path if
  this library is ever revisited: entities (+1) and case folding (+2)
  would reach 646/652 = 99.08%; tabs and laziness are the road to 652.
  Per the spec, the fallback is Hearth's own parser — which is what
  Phase 1 built (`src/hearth/markdown.mojo`), gated by the same corpus
  runner so its count is measured, never asserted.

## Templates — conorbronsdon/mojo-template

- **Repo:** https://github.com/conorbronsdon/mojo-template
- **Commit:** `086a9de6085e7b07d0ff44536e5f960791aabfbb` (v0.2.0,
  "Migrate to released Mojo 1.0")
- **License:** MIT
- **Builds on the pin:** yes; its own suites pass (78/78, 26/26).
- **Probe against SPEC.md §3's required surface** (variable + dotted
  lookup, loops, conditionals, filters, includes, one-level
  inheritance, a `get_url`-class builtin):
  - PASS: variable + dotted lookup, `{% for %}`, `{% if %}`, `|safe`.
  - RAISE: `{% include %}` — not supported.
  - RAISE: `{% extends %}` / `{% block %}` — not supported; both are
    documented non-goals upstream.
  - RAISE: function calls such as `{{ get_url(path='…') }}` — not
    supported.
- **Verdict: REJECT.** Includes and one-level inheritance are §3-required,
  not optional. Per the spec's fallback, Phase 1 implements exactly the
  §3 list in `src/hearth/templates.mojo`, including the corpus-exercised
  `get_url` builtin.

## Consequence

Both components are Hearth's own code, written under the Tiger Style
Mojo guide, and both are gated continuously: Markdown by
`tools/run_commonmark.sh` against the frozen corpus, templates by
`tests/test_templates.mojo` on the exact constructs the frozen site
corpora exercise.
