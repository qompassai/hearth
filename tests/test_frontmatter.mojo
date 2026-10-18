"""Unit tests for hearth.frontmatter + config: TOML front matter in the
shapes the frozen corpora use, including [extra] arrays of inline
tables."""

from hearth.frontmatter import split_frontmatter


def main() raises:
    var passed = 0
    var failed = 0

    var src = String(
        "+++\n"
        + "title = \"On the Joint Attention of Small Models\"\n"
        + "date = 2026-10-16\n"
        + "description = \"A position paper.\"\n\n"
        + "[extra]\n"
        + "authors = [\n"
        + "  {name = \"Matthew A. Porter\", url = \"https://orcid.org/0000-0002-0302-4812\"},\n"
        + "  {name = \"Qompass AI\", url = \"\"},\n"
        + "]\n"
        + "+++\n\nBody text.\n"
    )
    var split = split_frontmatter(src)
    if split[0]:
        passed += 1
        print("ok - front matter detected")
    else:
        failed += 1
        print("FAIL - front matter detected")
    var fm = split[1].copy()
    if fm.get("title").to_display() == "On the Joint Attention of Small Models":
        passed += 1
        print("ok - title")
    else:
        failed += 1
        print("FAIL - title: " + fm.get("title").to_display())
    if fm.get("date").to_display() == "2026-10-16":
        passed += 1
        print("ok - date carried as text")
    else:
        failed += 1
        print("FAIL - date: " + fm.get("date").to_display())
    var authors = fm.get("extra").get("authors")
    if authors.length() == 2 and authors.at(1).get("name").to_display() == "Qompass AI" and authors.at(1).get("url").to_display() == "":
        passed += 1
        print("ok - [extra] array of inline tables")
    else:
        failed += 1
        print("FAIL - authors shape")
    if split[2] == "\nBody text.\n":
        passed += 1
        print("ok - body preserved")
    else:
        failed += 1
        print("FAIL - body: [" + split[2] + "]")

    var plain = split_frontmatter("# Just markdown\n")
    if not plain[0] and plain[2] == "# Just markdown\n":
        passed += 1
        print("ok - no front matter passes through")
    else:
        failed += 1
        print("FAIL - no front matter passes through")

    var raised = False
    try:
        _ = split_frontmatter("+++\ntitle = \"x\"\n")
    except:
        raised = True
    if raised:
        passed += 1
        print("ok - unclosed front matter raises")
    else:
        failed += 1
        print("FAIL - unclosed front matter raises")

    print(String(passed) + " passed, " + String(failed) + " failed")
    if failed > 0:
        raise Error("test_frontmatter: failures present")
