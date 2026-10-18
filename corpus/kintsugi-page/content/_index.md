+++
title = "Kintsugi: Joint Attention for Byte-Size Models"
description = "Shared goals in multi-agent systems through verified uptake and visible repair — a deterministic commitment protocol, byte-size models as the perceptual layer, and repairs that stay visible in the record."
template = "index.html"

[extra]
conference = "Preprint · October 2026"
authors = [
  { name = "Matthew A. Porter", url = "https://qompass.ai", institution = "Qompass AI" },
]
links = [
  { name = "Paper", url = "" },
  { name = "Code", url = "https://github.com/qompassai/kintsugi" },
  { name = "arXiv", url = "" },
]
+++

<section class="highlight"><div class="highlight-inner">

## Abstract

Multi-agent systems built from language models coordinate through text, but text is not attention: an agent can receive a goal statement without taking it up, and two agents can act on divergent readings of the same plan without either noticing. Kintsugi adapts the developmental-psychology mechanism of joint attention to byte-size local models. A deterministic protocol holds the commitment record — who holds focus, in what phase, under what contention — while small adapted models serve as the perceptual layer: each maintains a compressed goal-state and must produce a canonical uptake restatement before acting. Restatements are compared across agents and against the record; divergence is surfaced as a first-class repair event in the shared log rather than hidden, so the common ground accumulates visible seams. Authority never transfers to the models: they propose, the protocol disposes.

</div></section>

## The mechanism

Joint attention has three parts, and Kintsugi maps each one to a mechanism:

- **A shared object of attention** — the coordination record itself: a single focus registry and a structured, append-only event log, identical for every participant.
- **Mutual awareness, verified** — before acting, each agent's model must restate the shared goal and its own role in canonical form. The restatement is checked against the record and against the other agents' restatements. A contribution counts only when uptake is evidenced — the grounding criterion, enforced as a gate.
- **Common ground, repaired in the open** — when restatements diverge, the divergence and its resolution are written into the record as first-class events and never edited away. The seams stay visible — the gold lines of the repair — and trust in the models is graduated against that history.

Commitment stays deterministic throughout: claims, phase changes, and contention resolutions are protocol acts, never model utterances. The models are the perceptual layer; the protocol is the commitment layer; the operator decides every graduation.

## The graduation ladder

Model responsibility widens only over measured evidence, and narrows mechanically on factual failure (F1 invented fact · F2 misclassification · F3 omission · F4 missing/stale output · F5 format drift):

| Stage | Name | What the model may do |
| :--- | :--- | :--- |
| D0 | Deterministic watch | Nothing — the protocol watches alone |
| D1 | Shadow | Produce goal-states and digests; nothing consumes them |
| D2 | Trusted first read | After 14 consecutive zero-failure nights, its digest is the operator's first read |
| D3 | Owns the watch | After 14 more clean nights incl. a real incident handled, divergence detection runs on its reading first |
| D4 | Full handoff of the watch | After 30 clean nights incl. two incident nights, it drafts graduation assessments — decisions stay the operator's |

Any factual failure demotes one stage and resets the streak; a fabricated fact in a graduation draft returns the system to D1.

## Pilot evidence

The perceptual task — faithful, canonical restatement of a coordination window — was piloted on the log's digest sub-task. A LoRA adapter (rank 8, alpha 16) trained on 36 deterministic-target examples in 44.8 s on one RTX A6000, evaluated on 20 held-out windows under an identical scorer:

| Model | Fully clean | Format conformant | Mean incident recall | Invented workers | Invented timestamps |
| :--- | :---: | :---: | :---: | :---: | :---: |
| granite-4.2-8b (base) | 0/20 | 1/20 | 0.175 | 3 | 4 |
| granite-4.2-8b + adapter | 19/20 | 20/20 | 1.000 | 1 | 0 |

A companion measurement disciplines the result: in a four-model served battery, both models that produced parseable answers misread contention phrased as refusal as assent — the false-common-ground failure class the design exists to prevent, and the reason the deterministic layer stays authoritative.

## Status

The manuscript in this repository is a complete draft: design, ladder, pilot evidence, and a pre-registered evaluation protocol. Two trials are specified in advance and marked {{ smallcaps(body="results pending") }} in the text until they run: Trial 0 (the pilot adapter, served through the local GGUF engine and re-scored at the endpoint) and Trial 1 (two agents under the uptake gate, with injected contention, a stale break, and a refusal-phrased contention). The full text, bibliography, and submission checklist live in `manuscript/` and `SUBMISSION.md` in the repository.

## BibTeX citation

```bibtex
@misc{porter2026kintsugi,
  author       = {Porter, Matthew A.},
  title        = {Kintsugi: Joint Attention for Byte-Size Models — Shared Goals in Multi-Agent Systems Through Verified Uptake and Visible Repair},
  year         = {2026},
  month        = oct,
  howpublished = {Preprint},
  url          = {https://github.com/qompassai/kintsugi}
}
```
