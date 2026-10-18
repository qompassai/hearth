# Hearth

<a href="./LICENSE"><img src="https://img.shields.io/badge/License-Apache%202.0-blue.svg" alt="License: Apache 2.0"></a>

A Tiger Style Mojo static site generator: a single native Mojo binary that turns Markdown + templates into a static site — deterministic output, bounded everything, zero runtime dependencies, no Node, no npm, ever.

The name is the fixed fire at the center of the home; a site generator builds homes. Hearth is the reference implementation for the estate's Tiger Style Mojo guide: if the guide and the code ever disagree, that is a finding against one of them, recorded either way.

## Status

**Phase 0 — spec, frozen corpus, and baselines.** No generator code exists yet. Phase 1 (the core pipeline) starts on the spec's terms; see `SPEC.md` §6.

## What's here

- **`SPEC.md`** — the governing spec (draft v0.1): purpose, the parity definition, gates and baselines, architecture, non-goals, and the toolchain discipline.
- **`corpus/`** — the frozen evaluation corpus (frozen 2026-10-16): the CommonMark 0.31.2 spec suite (652 examples), the Kintsugi publication page as built by the pinned Zola 0.22.1 reference, and a deterministic 1,000-page bench site. `corpus/MANIFEST.sha256` carries 1,012 SHA-256 entries; every corpus file verifies against it. (The manifest's self-entry cannot verify against its own contents — a known artifact of how it was generated, recorded here rather than silently edited: changing any corpus file requires a spec amendment and re-baselining, per `SPEC.md` §2.)
- **`pixi.toml` / `pixi.lock`** — the pinned Mojo toolchain (below).

Baselines (primo, Zola 0.22.1, binding — `SPEC.md` §4): `kintsugi-page` build median 12 ms; `bench-1000` build median 126 ms.

## Toolchain

Pinned per `SPEC.md` §8: a reviewed release, never a moving nightly.

- **Pin:** Mojo **1.1.0** (`mojo ==1.1.0` in `pixi.toml`, locked in `pixi.lock`), from the Modular channel (`https://conda.modular.com/max`) with conda-forge. Pixi 0.81.0.
- **Why this release:** Mojo 1.0 (2026-08-11) ended the pre-1.0 churn cycle and open-sourced the compiler; 1.1.0 (2026-09-17) is the current stable, with core stdlib surfaces (`String`, `List`, `SIMD`) explicitly marked stable. The pin holds until a scheduled re-baseline — upgrades are explicit acts, never surprises.
- **Build evidence (primo, 2026-10-17):** `pixi install` solves and installs clean; `mojo --version` reports `Mojo 1.1.0 (8189361e)`; a probe program (list append + indexed sum) builds with `mojo build` and runs correctly. Machine: 13th Gen Intel Core i7-13620H, Linux 7.2.9-zen x86_64 (Arch Linux).

## Gates (summary — `SPEC.md` §4 is authoritative)

1. CommonMark suite: 652/652.
2. DOM-equivalence with the reference output on both site corpora: 100% of pages.
3. `bench-1000` build wall time at or under the Zola baseline (2× faster is the goal, claimed only when measured).
4. Determinism: consecutive builds byte-identical.
5. `bench-1000` peak RSS ≤ 500 MB.
6. Full test suite green with a 50/50 validation/adversarial split; Neovim IDE gate at zero diagnostics for every Mojo file.

## License

Apache-2.0. See `LICENSE`.
