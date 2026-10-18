# Hearth — a Tiger Style Mojo static site generator

**Status:** Ratified v0.1 (Matt, 2026-10-17). Commissioned by Matt, 2026-10-16.
**Name:** Hearth (ruled by Matt, 2026-10-16) — the fixed fire at the center of the home; a site generator builds homes. Verified 2026-10-16: free on crates.io and as `github.com/qompassai/hearth` (all other candidates checked were taken on crates.io).
**One-line summary:** A single native Mojo binary that turns Markdown + templates into a static site, built under the estate's Tiger Style Mojo guide as that guide's reference implementation — deterministic output, bounded everything, zero runtime dependencies, no Node, no npm, ever.

Phase 0 is this document plus the frozen corpus (§2) plus recorded baselines (§4). No generator code is written before Matt ratifies this spec — the Superpose pattern: profile and targets first, code second.

<details>
<summary>§1 — Purpose and positioning</summary>

- Hearth exists because the estate's publication surfaces (the Kintsugi page today; docs and future papers behind it) currently depend on either an npm-carrying Astro stack or a pinned Zola binary whose latest release (0.23) removed shortcodes and broke its theme ecosystem. Owning the generator removes both dependencies and gives the estate a Mojo flagship that is not a kernel: a complete, user-facing tool.
- Hearth is an **offline native binary**. The standing Mojo ruling (2026-10-12: no credible Mojo-to-WASM web path) does not apply — nothing here runs in a browser. SSG output is plain HTML/CSS files, hostable anywhere.
- Hearth is the **reference implementation for tiger-style-mojo**: pinned compiler, explicit contracts, bounded loops and buffers, deterministic output ordering, assertions in debug builds, and a 50/50 validation/adversarial test split. If the guide and the code ever disagree, that is a finding against one of them, recorded either way.
- **Non-positioning:** Hearth is not a Zola/Hugo clone and does not read their config formats. It has its own small config, designed for the estate's actual sites. Compatibility is measured at the **output** level against the reference implementation on the frozen corpus (§3), not at the input level.

</details>

<details>
<summary>§2 — The frozen corpus</summary>

All parity and performance claims are made against this corpus, frozen 2026-10-16 at `~/workspace/mojo-ssg-spec/corpus/` with a SHA-256 manifest (`MANIFEST.sha256`, 1,012 entries, manifest hash `8e68734c5ad2f101777a6b610a7fb50c4c86c99b29bcb50d3ec6702f9cb60e26`). Changing any corpus file after ratification requires a spec amendment and re-baselining.

| Corpus | Contents | What it proves |
|---|---|---|
| `spec.txt` | CommonMark spec 0.31.2, all **652 examples** (sha256 `bfef4ddc…aa3b82`) | Parser correctness against the standard, not against vibes |
| `kintsugi-page/` | The Kintsugi publication page as built by the Zola prototype: `content/_index.md`, Tera templates, shortcode, hand-written CSS, `zola.toml` | Real-site output equivalence incl. tables, inline HTML band, small-caps, pills, BibTeX block |
| `bench-1000/` | Deterministic synthetic site: 1,000 generated pages (seed 20261016; headings, tables, lists, code blocks, inter-page links), minimal templates | Build-speed and memory measurement at scale |

</details>

<details>
<summary>§3 — What "on par" means (parity definition)</summary>

- **Parser parity:** score on the frozen CommonMark suite. The community `mojo-markdown` parser claims 98.6% conformance; Hearth's v1.0 gate is **652/652** (see §5 for the adoption-spike rule — the claim is measured, never inherited).
- **Output equivalence (site corpora):** Hearth's output for `kintsugi-page/` and `bench-1000/` must equal the reference output under **DOM-normalized comparison**: parse both HTML documents; compare element trees with attribute order ignored, whitespace-only text nodes collapsed, and void-element spelling normalized. Byte-identical output is the stretch goal, not the gate — DOM equality is what readers and browsers experience.
- **Feature parity is scoped to what the corpora exercise** plus this explicit v0.1 list: Markdown (CommonMark + tables + footnotes + strikethrough + heading anchors), TOML front matter, templates (variables, loops, conditionals, includes, one layout level of inheritance), inline shortcodes with named arguments, body shortcodes whose bodies are Markdown-rendered (the exact case Zola 0.22 fails and the Kintsugi page needs), static asset copying, generated table of contents, `build` and `check` commands (check = internal-link and anchor validation).
- Anything not listed is not v0.1 scope, however standard it is in other generators (§7).

</details>

<details>
<summary>§4 — Gates and baselines</summary>

Reference implementation: **Zola 0.22.1**, pinned by SHA-256 (`0ca09aa4…f22ef`), the version verified working in the Kintsugi prototype (0.23 is disqualified as a reference: it removed shortcodes).

Baselines (primo, 2026-10-16, Zola 0.22.1, five runs each — binding):

| Measurement | Baseline |
|---|---|
| `kintsugi-page` build | median **12 ms** (range 10–14); output 32 KB |
| `bench-1000` build | median **126 ms** (range 102–141); output 4.0 MB / 1,001 pages |
| Zola binary size | 43 MB (single file) |

(Sandbox-VM figures from the prototype session — ~53 ms and ~355 ms respectively — are superseded by these.)

Hearth v1.0 gates (all on primo, same machine as baselines):

1. CommonMark suite: **652/652**.
2. DOM-equivalence on both site corpora: **100% of pages**.
3. `bench-1000` build wall time: **≤ Zola baseline** (hard floor); **≥2× faster** is the goal, claimed only when measured — the randori rule: no performance claim without a timed run and a verified-identical output.
4. Determinism: two consecutive builds of every corpus produce **byte-identical** output trees.
5. Memory: `bench-1000` build peak RSS **≤ 500 MB** (Superpose target lineage).
6. CLI floor: `hearth check` first result **< 1 s** on `kintsugi-page`; **every** command's startup-to-first-output < 100 ms excluding build work.
7. Tiger Style gates: `mojo build` clean on the pinned toolchain; full test suite green with the 50/50 validation/adversarial split (adversarial = malformed Markdown, pathological nesting, oversized inputs, front-matter fuzz — all bounded, none crashing); Neovim IDE gate zero errors before any file is called done.

</details>

<details>
<summary>§5 — Architecture</summary>

Pipeline (each stage a module with an explicit input/output contract; alphabetical order per estate rule): `assets` → `build` → `check` → `config` → `frontmatter` → `markdown` → `render` → `scan` → `shortcodes` → `templates` → `toc` → `write`.

- **`scan`** walks the content tree with explicit bounds (max files, max file size, max depth — constants, not heuristics) and produces the page inventory in sorted order. Determinism starts here.
- **`frontmatter` / `config`** are hand-rolled, bounded scanners for the TOML subset the corpora use (Mojo has no stdlib TOML). The subset is enumerated in the module contract; anything outside it is a hard error naming the file and line — never a silent mis-parse.
- **`markdown`** — adoption spike first (Phase 1, rung 1): measure `mojo-markdown` against the frozen suite. **Adopt** it (vendored, pinned, with its failing examples either fixed upstream-style or carried as a patched delta) only if it reaches ≥ 99% and every failure is understood; otherwise Hearth writes its own parser against the same gate. The decision is recorded with numbers in the project memory either way. No silent substitution — this is the gpui-probe guardrail applied to libraries.
- **`templates`** — same spike pattern for `mojo-template` against the corpus templates; fallback is a minimal own engine implementing exactly the §3 template list.
- **`shortcodes`** — inline and body forms; bodies are rendered as Markdown before template insertion (Hearth's contract, fixing the behavior the Kintsugi page actually needs).
- **`write`** — atomic output: build into a temp sibling directory, rename into place. A failed build never leaves a half-written site.

Mojo-specific constraints accepted up front: no stdlib regex (all scanning is hand-written state machines — slower to write, faster to reason about, and the Tiger Style shape anyway); Unicode handling per the pinned stdlib, with grapheme edge cases carried as adversarial tests; pre-1.0 language churn absorbed by the §8 pin, with re-baselining as an explicit, scheduled act — never a surprise.

</details>

<details>
<summary>§6 — Phases</summary>

- **Phase 0 — spec + corpus + baselines (this document).** Primo baselines captured 2026-10-16 (§4). Exit: Matt ratifies; repo creation is Matt's word.
- **Phase 1 — core pipeline to corpus parity.** Rungs: adoption spikes (markdown, templates) → scan/config/frontmatter → render pipeline → shortcodes/TOC → `build` + `check`. Exit: gates §4.1, §4.2, §4.4 green.
- **Phase 2 — performance and hardening.** Profiling on `bench-1000` before any optimization (measure the share, then optimize it); parallelism only where profiling earns it. Exit: §4.3, §4.5, §4.6 green; adversarial suite complete.
- **Phase 3 — extensions, each its own gated addition, in this order:** RSS/Atom feed + sitemap; syntax highlighting; Sass; image pipeline; dev server with live reload; i18n. Each lands only with corpus additions proving the need (a real estate site that uses it), never speculatively.

</details>

<details>
<summary>§7 — Non-goals for v0.1</summary>

Sass/SCSS compilation; image resizing/optimization; syntax highlighting; feeds and sitemap; search index; live-reload dev server; i18n; taxonomies and pagination; themes or any third-party template compatibility; Zola/Hugo config or content migration tooling; a plugin system. Each is a Phase 3 candidate with its own gate, or nothing.

</details>

<details>
<summary>§8 — Toolchain and build discipline</summary>

- Mojo version **pinned** via pixi manifest + lockfile, per the tiger-style-mojo guide: a reviewed release, never a moving nightly as a reproducibility claim. The pin is recorded in the repo with full build evidence (compiler version, CPU target, OS, optimization/assertion settings).
- All builds and gates run on **primo** (the estate's benchmark and validation machine); the Neovim IDE gate (zero diagnostics) applies to every Mojo file before it is called done.
- Distribution: single static binary per platform, Linux x86_64 first; GitHub Releases now, Bunker when it ships. No crates.io presence is required (the name is nonetheless free there as of 2026-10-16).
- License: **Apache-2.0** (estate standard).

</details>

<details>
<summary>§9 — Risks, stated plainly</summary>

- **Language churn:** Mojo is pre-1.0; the pinned stdlib will move under the project. Mitigation: the §8 pin + scheduled re-baselining; the corpus gates make a breaking upgrade visible immediately.
- **Building-block bus factor:** `mojo-markdown` / `mojo-template` are small community projects. Mitigation: the §5 spike measures before adopting, adoption means vendoring at a pin, and the fallback (own parser) is specced, not improvised.
- **Scope gravity:** SSGs accrete features. Mitigation: §7 is contractual; a feature enters only through Phase 3's need-proving rule.
- **The speed claim could fail.** Zola is a mature Rust binary; Hearth may reach parity without beating it. That outcome is acceptable and reportable — parity with zero npm and an owned toolchain is the floor value; §4.3's goal is a goal, not a promise.

</details>

<details>
<summary>§10 — Decisions</summary>

- **Ruled:** name = **Hearth** (Matt, 2026-10-16). Reference implementation = Zola 0.22.1. Corpus as frozen in §2.
- **Open for Matt:** (1) ratify this spec (with any amendments); (2) create `github.com/qompassai/hearth` (his word, as with all repos); (3) Phase 1 start — queued behind the existing board (Fork 2, rose provisioning, digest trial) unless Matt re-prioritizes.

</details>
