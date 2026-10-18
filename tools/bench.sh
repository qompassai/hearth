#!/usr/bin/env bash
# Bench harness: Hearth vs the pinned Zola reference on the two frozen
# site corpora. Five runs each, medians reported; peak RSS is the max of
# the per-run maxima. Also the determinism gate: two consecutive Hearth
# builds must be byte-identical.
#
# Binding baselines (SPEC.md S4, primo, Zola 0.22.1): kintsugi-page
# median 12 ms, bench-1000 median 126 ms. Zola is timed here too, on
# this machine, so the report can show both the live comparison and the
# recorded baseline.
set -euo pipefail
cd "$(dirname "$0")/.."

RUNS=5
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mojo build -I src -O 2 -o build/hearth src/main.mojo 2>/dev/null \
  || mojo build -I src -o build/hearth src/main.mojo

ZOLA="${ZOLA:-}"
if [ -z "$ZOLA" ]; then
  ZOLA="$(command -v zola || true)"
fi
if [ -z "$ZOLA" ] && [ -x "$HOME/.local/bin/zola" ]; then
  ZOLA="$HOME/.local/bin/zola"
fi
if [ -z "$ZOLA" ] && [ -x "$HOME/scratch/mojo-ssg-baseline/tools/zola" ]; then
  ZOLA="$HOME/scratch/mojo-ssg-baseline/tools/zola"
fi

base_url_of() {
  grep -E '^base_url' "$1/zola.toml" | head -1 | sed -E 's/^[^=]*=[[:space:]]*//; s/"//g'
}

time_runs() {
  # $1 = label, $2.. = command; echoes "median_ms max_rss_kb"
  local label="$1"; shift
  local times=() rss=()
  local i
  for i in $(seq 1 "$RUNS"); do
    /usr/bin/time -v "$@" > /dev/null 2> "$WORK/time.txt"
    local elapsed rss_kb
    elapsed="$(grep 'Elapsed (wall clock)' "$WORK/time.txt" | sed -E 's/.*: //')"
    rss_kb="$(grep 'Maximum resident set size' "$WORK/time.txt" | sed -E 's/.*: //')"
    times+=("$(python3 -c "
t = '$elapsed'.split(':')
s = float(t[-1]) + 60 * (float(t[-2]) if len(t) > 1 else 0)
print(f'{s * 1000:.1f}')")")
    rss+=("$rss_kb")
  done
  python3 -c "
times = sorted(float(x) for x in '''${times[*]}'''.split())
rss = [int(x) for x in '''${rss[*]}'''.split()]
print(f'{times[len(times) // 2]:.1f} {max(rss)}')"
}

bench_corpus() {
  local name="$1" baseline="$2"
  local fixture="corpus/$name"
  local base_url
  base_url="$(base_url_of "$fixture")"
  read -r h_ms h_rss <<< "$(time_runs hearth ./build/hearth build "$fixture" -o "$WORK/out-$name" --base-url "$base_url")"
  local z_line="zola: not found"
  if [ -n "$ZOLA" ]; then
    cp -r "$fixture" "$WORK/zola-$name"
    read -r z_ms z_rss <<< "$(time_runs zola bash -c "cd \"$WORK/zola-$name\" && exec \"$ZOLA\" build")"
    z_line="zola median ${z_ms} ms, peak RSS $((z_rss / 1024)) MB"
  fi
  ./build/hearth build "$fixture" -o "$WORK/det-a" --base-url "$base_url" > /dev/null
  ./build/hearth build "$fixture" -o "$WORK/det-b" --base-url "$base_url" > /dev/null
  local det="DIFFER"
  if diff -r "$WORK/det-a" "$WORK/det-b" > /dev/null; then
    det="byte-identical"
  fi
  echo "$name: hearth median ${h_ms} ms, peak RSS $((h_rss / 1024)) MB | $z_line | binding baseline ${baseline} ms | determinism: $det"
}

bench_corpus kintsugi-page 12
bench_corpus bench-1000 126
