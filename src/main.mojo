"""Hearth CLI: `hearth build|check|version [SOURCE_DIR] [options]`.

build  Render the site (default SOURCE_DIR is the working directory).
       -o/--output DIR    output directory (default: SOURCE_DIR/public)
       --base-url URL     override hearth.toml's base_url
check  Validate a built output tree's internal links and anchors.
version  Print the Hearth version.
"""

from hearth.build import build_site
from hearth.check import check_output
from std.sys import argv

comptime VERSION: String = "0.1.0"


def _usage() -> String:
    return (
        "hearth "
        + VERSION
        + "\nusage: hearth build|check|version [SOURCE_DIR] "
        + "[-o DIR] [--base-url URL]"
    )


def main() raises:
    var args = argv()
    if len(args) < 2:
        print(_usage())
        return
    var command = String(args[1])
    if command == "version" or command == "--version":
        print("hearth " + VERSION)
        return
    if command != "build" and command != "check":
        print(_usage())
        raise Error("unknown command: " + command)
    var source = String(".")
    var output = String()
    var base_url = String()
    var i = 2
    while i < len(args):
        var a = String(args[i])
        if a == "-o" or a == "--output":
            if i + 1 >= len(args):
                raise Error(a + " requires a value")
            output = String(args[i + 1])
            i += 2
            continue
        if a == "--base-url":
            if i + 1 >= len(args):
                raise Error(a + " requires a value")
            base_url = String(args[i + 1])
            i += 2
            continue
        if a.startswith("-"):
            raise Error("unknown option: " + a)
        source = a.copy()
        i += 1
    if command == "check":
        var target = output if output != "" else source + "/public"
        var problems = check_output(target)
        for ref p in problems:
            print("check: " + p)
        if len(problems) > 0:
            raise Error(
                "check: " + String(len(problems)) + " problem(s) in " + target
            )
        print("check: " + target + " OK")
        return
    var result = build_site(source, output, base_url)
    print(
        "built "
        + String(result.pages)
        + " page(s), "
        + String(result.sections)
        + " section(s), "
        + String(result.files_written)
        + " file(s) -> "
        + result.output_dir
    )
    for ref p in result.problems:
        print("check: " + p)
    if len(result.problems) > 0:
        raise Error(
            "build succeeded but check found "
            + String(len(result.problems))
            + " problem(s)"
        )
