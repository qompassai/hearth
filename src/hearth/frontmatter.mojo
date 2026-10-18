"""Front matter extraction: a `+++`-delimited TOML block at the very start
of a Markdown file (SPEC.md S3: TOML front matter).

`split_frontmatter` returns (present, front matter as a dict Value, body).
A file that does not open with `+++` on its first line has no front matter
and its body is the whole file. An opening `+++` with no closing line is
a hard error — never a silent mis-parse.
"""

from hearth.config import parse_toml
from hearth.value import Value


def split_frontmatter(source: String) raises -> Tuple[Bool, Value, String]:
    var bytes = source.as_bytes()
    if source.byte_length() < 4 or not (
        bytes[0] == 0x2B and bytes[1] == 0x2B and bytes[2] == 0x2B
    ):
        return (False, Value.dict(List[String](), List[Value]()), source.copy())
    # Find the end of the first line.
    var i = 3
    if i < len(bytes) and bytes[i] == 0x0D:
        i += 1
    if i >= len(bytes) or bytes[i] != 0x0A:
        return (False, Value.dict(List[String](), List[Value]()), source.copy())
    i += 1
    var fm_start = i
    # Scan lines for a closing +++ on its own line.
    var line_start = i
    while line_start < len(bytes):
        var line_end = line_start
        while line_end < len(bytes) and bytes[line_end] != 0x0A:
            line_end += 1
        var line = String(
            StringSlice(unsafe_from_utf8=bytes[line_start:line_end])
        )
        var trimmed = line.strip()
        if String(trimmed) == "+++":
            var fm_text = String(
                StringSlice(unsafe_from_utf8=bytes[fm_start:line_start])
            )
            var body_start = line_end + 1
            if body_start > len(bytes):
                body_start = len(bytes)
            var body = String(
                StringSlice(unsafe_from_utf8=bytes[body_start : len(bytes)])
            )
            var fm = parse_toml(fm_text)
            return (True, fm^, body^)
        line_start = line_end + 1
    raise Error("frontmatter: opening +++ has no closing +++ line")
