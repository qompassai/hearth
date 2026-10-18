"""CommonMark conformance driver: renders every extracted spec example
with Hearth's own Markdown engine and compares byte-for-byte.

Usage: conformance CASES_FILE
Prints each failing example (number + section), then a final
"PASS n/652" line. Exit code is 0 only when every example passes.
"""

from hearth.markdown import render_html
from std.sys import argv


def _fields(record: String) -> Tuple[String, String, String, String]:
    var f1 = record.find("\x1f")
    var f2 = record.find("\x1f", f1 + 1)
    var f3 = record.find("\x1f", f2 + 1)
    return (
        String(record[byte=:f1]),
        String(record[byte=f1 + 1 : f2]),
        String(record[byte=f2 + 1 : f3]),
        String(record[byte=f3 + 1 :]),
    )


def main() raises:
    var args = argv()
    if len(args) < 2:
        raise Error("usage: conformance CASES_FILE")
    var data = open(String(args[1]), "r").read()
    var records = data.split("\x1e")
    var passed = 0
    var total = 0
    var failing = List[String]()
    for ref rec0 in records:
        var record = String(rec0)
        if String(record.strip()) == "":
            continue
        var fields = _fields(record)
        total += 1
        var got = render_html(fields[2])
        if got == fields[3]:
            passed += 1
        else:
            failing.append(fields[1] + " (" + fields[0] + ")")
    for ref f in failing:
        print("FAIL example " + f)
    print(
        "PASS "
        + String(passed)
        + "/"
        + String(total)
        + " ("
        + String(len(failing))
        + " failing)"
    )
    if passed != total:
        raise Error("conformance: " + String(len(failing)) + " example(s) failing")
