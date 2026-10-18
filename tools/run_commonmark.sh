#!/usr/bin/env bash
# Corpus gate: verify the frozen corpus against MANIFEST.sha256, extract
# the CommonMark examples, build the conformance driver, and run it.
# The manifest's self-entry cannot verify (documented in README.md);
# exactly that one line is excluded from the check.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
tmp_manifest="$(mktemp)"
trap 'rm -f "$tmp_manifest"' EXIT
grep -v 'MANIFEST\.sha256$' corpus/MANIFEST.sha256 > "$tmp_manifest"
(cd corpus && sha256sum -c --quiet "$tmp_manifest")
echo "manifest: all non-self entries verify"

python3 tools/extract_spec_cases.py corpus/spec.txt build/spec_cases.txt
mojo build -I src -o build/conformance tools/conformance.mojo
./build/conformance build/spec_cases.txt
