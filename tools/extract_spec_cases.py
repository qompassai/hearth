#!/usr/bin/env python3
"""Extract the CommonMark examples from the frozen corpus spec.txt into
the record format the conformance driver consumes:

    section \x1f number \x1f markdown \x1f html \x1e   (per example)

Tabs in the spec text are written as U+2192 and restored here. The
output is byte-identical to the (independently produced) case file of
the upstream mojo-markdown project, which is how the extraction was
validated; tools/run_commonmark.sh re-checks the example count.
"""

import sys

FENCE = "`" * 32
TAB_MARK = "\u2192"


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: extract_spec_cases.py SPEC_TXT OUT", file=sys.stderr)
        return 2
    lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
    records = []
    section = ""
    i = 0
    number = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("## "):
            section = line[3:].strip()
            i += 1
            continue
        if line.startswith(FENCE) and "example" in line:
            i += 1
            md: list[str] = []
            while lines[i] != ".":
                md.append(lines[i])
                i += 1
            i += 1
            html: list[str] = []
            while not lines[i].startswith(FENCE):
                html.append(lines[i])
                i += 1
            number += 1
            md_text = ("\n".join(md) + "\n" if md else "").replace(TAB_MARK, "\t")
            html_text = ("\n".join(html) + "\n" if html else "").replace(
                TAB_MARK, "\t"
            )
            # One example in the corpus (207) legitimately expects an
            # empty HTML body, which the join above renders as "\n".
            if html_text == "\n" and not html:
                html_text = ""
            records.append(
                f"{section}\x1f{number}\x1f{md_text}\x1f{html_text}\x1e"
            )
        i += 1
    if number != 652:
        print(f"error: expected 652 examples, extracted {number}", file=sys.stderr)
        return 1
    with open(sys.argv[2], "w", encoding="utf-8") as fh:
        fh.write("".join(records))
    print(f"extracted {number} examples")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
