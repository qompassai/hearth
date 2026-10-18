"""Hearth's own Markdown parser and HTML renderer.

Written for SPEC.md S5's fallback path (the adoption spikes for the
community libraries did not clear their bars — see spikes/SPIKES.md).
Byte-level, line-oriented block parsing with a recursive inline parser,
plus the S3 extensions: GFM tables, strikethrough, footnotes, and
heading anchor ids.

Deliberate simplifications, all measured by the corpus gate rather than
hidden: link reference definitions are collected in a pre-pass (so their
block placement rules are looser than the spec's), emphasis uses a
flanking-aware matcher without the full rule-of-3 machinery, list
content indentation follows the marker's content column without
per-container column state, and label matching folds ASCII case only.
The CommonMark score this earns is whatever tools/run_commonmark.sh
reports — the number is the contract.
"""

from hearth.value import Value

comptime MAX_BLOCK_DEPTH: Int = 64
comptime MAX_INPUT_BYTES: Int = 64 << 20


struct Heading(Copyable, Movable):
    var level: Int
    var id: String
    var text: String

    def __init__(out self, level: Int, id: String, text: String):
        self.level = level
        self.id = id.copy()
        self.text = text.copy()


struct MdResult(Copyable, Movable):
    var html: String
    var headings: List[Heading]

    def __init__(out self):
        self.html = String()
        self.headings = List[Heading]()


struct RefDef(Copyable, Movable):
    var dest: String
    var title: String

    def __init__(out self, dest: String, title: String):
        self.dest = dest.copy()
        self.title = title.copy()


# ---------- byte helpers ----------


def _sub(s: String, a: Int, b: Int) -> String:
    var bytes = s.as_bytes()
    var lo = a
    var hi = b
    if lo < 0:
        lo = 0
    if hi > len(bytes):
        hi = len(bytes)
    if lo >= hi:
        return String()
    return String(StringSlice(unsafe_from_utf8=bytes[lo:hi]))


def _is_space(b: UInt8) -> Bool:
    return b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D or b == 0x0B or b == 0x0C


def _is_punct(b: UInt8) -> Bool:
    return (UInt8(0x21) <= b and b <= UInt8(0x2F)) or (UInt8(0x3A) <= b and b <= UInt8(0x40)) or (
        UInt8(0x5B) <= b and b <= UInt8(0x60)
    ) or (UInt8(0x7B) <= b and b <= UInt8(0x7E))


def _is_digit(b: UInt8) -> Bool:
    return UInt8(0x30) <= b and b <= UInt8(0x39)


def _is_alpha(b: UInt8) -> Bool:
    return (UInt8(0x41) <= b and b <= UInt8(0x5A)) or (UInt8(0x61) <= b and b <= UInt8(0x7A))


def _lower_ascii(b: UInt8) -> UInt8:
    if UInt8(0x41) <= b and b <= UInt8(0x5A):
        return b + 0x20
    return b


def escape_text(s: String) -> String:
    var bytes = s.as_bytes()
    var out = String()
    var run = 0
    for i in range(len(bytes)):
        var b = bytes[i]
        if b == 0x26 or b == 0x3C or b == 0x3E or b == 0x22:
            if i > run:
                out += String(StringSlice(unsafe_from_utf8=bytes[run:i]))
            if b == 0x26:
                out += "&amp;"
            elif b == 0x3C:
                out += "&lt;"
            elif b == 0x3E:
                out += "&gt;"
            else:
                out += "&quot;"
            run = i + 1
    out += String(StringSlice(unsafe_from_utf8=bytes[run:]))
    return out^


def escape_attr(s: String) -> String:
    var bytes = s.as_bytes()
    var out = String()
    var run = 0
    for i in range(len(bytes)):
        var b = bytes[i]
        if b == 0x26 or b == 0x3C or b == 0x3E or b == 0x22:
            if i > run:
                out += String(StringSlice(unsafe_from_utf8=bytes[run:i]))
            if b == 0x26:
                out += "&amp;"
            elif b == 0x3C:
                out += "&lt;"
            elif b == 0x3E:
                out += "&gt;"
            else:
                out += "&quot;"
            run = i + 1
    out += String(StringSlice(unsafe_from_utf8=bytes[run:]))
    return out^


def encode_uri(s: String) -> String:
    """Percent-encode the bytes a URI may not carry literally:
    controls, space, non-ASCII, and the printable characters the
    reference href escaper rejects (\" < > \\ [ ] ^ ` { | })."""
    var bytes = s.as_bytes()
    var out = String()
    comptime HEX = "0123456789ABCDEF"
    for i in range(len(bytes)):
        var b = bytes[i]
        var unsafe = (
            b >= UInt8(0x80)
            or b <= UInt8(0x20)
            or b == 0x7F
            or b == 0x22
            or b == 0x3C
            or b == 0x3E
            or b == 0x5B
            or b == 0x5C
            or b == 0x5D
            or b == 0x5E
            or b == 0x60
            or b == 0x7B
            or b == 0x7C
            or b == 0x7D
        )
        if unsafe:
            out += "%"
            out += String(StringSlice(unsafe_from_utf8=HEX.as_bytes()[Int(b >> 4) : Int(b >> 4) + 1]))
            out += String(StringSlice(unsafe_from_utf8=HEX.as_bytes()[Int(b & 0xF) : Int(b & 0xF) + 1]))
        else:
            out += String(StringSlice(unsafe_from_utf8=bytes[i : i + 1]))
    return out^


def _fold_cp(cp: Int, s: String, pos: Int, length: Int) -> String:
    """The lowercase mapping of one codepoint, for label matching:
    ASCII, Latin-1, Greek, Cyrillic, Armenian, and fullwidth ranges,
    plus the dotted-capital-I special case."""
    if 0x41 <= cp and cp <= 0x5A:
        return _sub("abcdefghijklmnopqrstuvwxyz", cp - 0x41, cp - 0x41 + 1)
    if 0xC0 <= cp and cp <= 0xDE and cp != 0xD7:
        return _decode_codepoint(cp + 0x20)
    if cp == 0x130:  # İ folds to i + combining dot above (U+0307)
        return String("i") + _decode_codepoint(0x307)
    if cp == 0x178:
        return _decode_codepoint(0xFF)
    if cp == 0x386:
        return _decode_codepoint(0x3AC)
    if cp == 0x388:
        return _decode_codepoint(0x3AD)
    if cp == 0x389:
        return _decode_codepoint(0x3AE)
    if cp == 0x38A:
        return _decode_codepoint(0x3AF)
    if cp == 0x38C:
        return _decode_codepoint(0x3CC)
    if cp == 0x38E:
        return _decode_codepoint(0x3CD)
    if cp == 0x38F:
        return _decode_codepoint(0x3CE)
    if (0x391 <= cp and cp <= 0x3A1) or (0x3A3 <= cp and cp <= 0x3AB):
        return _decode_codepoint(cp + 0x20)
    if 0x400 <= cp and cp <= 0x40F:
        return _decode_codepoint(cp + 0x50)
    if 0x410 <= cp and cp <= 0x42F:
        return _decode_codepoint(cp + 0x20)
    if 0x531 <= cp and cp <= 0x556:
        return _decode_codepoint(cp + 0x30)
    if 0xFF21 <= cp and cp <= 0xFF3A:
        return _decode_codepoint(cp + 0x20)
    # Full-fold specials (CaseFolding.txt F mappings and symbol forms).
    if cp == 0xDF or cp == 0x1E9E:
        return String("ss")
    if cp == 0x17F:
        return String("s")
    if cp == 0x138:
        return String("k")
    if cp == 0xB5:
        return _decode_codepoint(0x3BC)
    if cp == 0x3C2:
        return _decode_codepoint(0x3C3)
    if cp == 0x3D0:
        return _decode_codepoint(0x3B2)
    if cp == 0x3D1 or cp == 0x3F4:
        return _decode_codepoint(0x3B8)
    if cp == 0x3D5:
        return _decode_codepoint(0x3C6)
    if cp == 0x3D6:
        return _decode_codepoint(0x3C0)
    if cp == 0x3F0:
        return _decode_codepoint(0x3BA)
    if cp == 0x3F1:
        return _decode_codepoint(0x3C1)
    if cp == 0x3F5:
        return _decode_codepoint(0x3B5)
    if cp == 0xFB00:
        return String("ff")
    if cp == 0xFB01:
        return String("fi")
    if cp == 0xFB02:
        return String("fl")
    if cp == 0xFB03:
        return String("ffi")
    if cp == 0xFB04:
        return String("ffl")
    if cp == 0xFB05 or cp == 0xFB06:
        return String("st")
    if (cp == 0x1C4 or cp == 0x1C5):
        return _decode_codepoint(0x1C6)
    if (cp == 0x1C7 or cp == 0x1C8):
        return _decode_codepoint(0x1C9)
    if (cp == 0x1CA or cp == 0x1CB):
        return _decode_codepoint(0x1CC)
    if (cp == 0x1F1 or cp == 0x1F2):
        return _decode_codepoint(0x1F3)
    if 0x100 <= cp and cp <= 0x12E and cp % 2 == 0 and cp != 0x130:
        return _decode_codepoint(cp + 1)
    if 0x139 <= cp and cp <= 0x148 and cp % 2 == 1:
        return _decode_codepoint(cp + 1)
    return _sub(s, pos, pos + length)


def normalize_label(s: String) -> String:
    """Label matching form: internal Unicode-whitespace runs
    collapse to one space, ends are trimmed, case is folded."""
    var bytes = s.as_bytes()
    var out = String()
    var pending_space = False
    var i = 0
    while i < len(bytes):
        var dec = _decode_cp(s, i)
        var cp = dec[0]
        if (
            cp == 0x20
            or cp == 0x09
            or cp == 0x0A
            or cp == 0x0D
            or cp == 0x0B
            or cp == 0x0C
        ):
            pending_space = True
            i += dec[1]
            continue
        if pending_space and out.byte_length() > 0:
            out += " "
        pending_space = False
        out += _fold_cp(dec[0], s, i, dec[1])
        i += dec[1]
    return out^


def slugify(text: String) -> String:
    var bytes = text.as_bytes()
    var out = String()
    var last_dash = True  # suppresses a leading dash
    for i in range(len(bytes)):
        var b = _lower_ascii(bytes[i])
        if (UInt8(0x61) <= b and b <= UInt8(0x7A)) or (UInt8(0x30) <= b and b <= UInt8(0x39)) or b >= UInt8(0x80):
            if b == bytes[i]:
                out += String(StringSlice(unsafe_from_utf8=bytes[i : i + 1]))
            else:
                out += _sub(
                    "abcdefghijklmnopqrstuvwxyz", Int(b) - 0x61, Int(b) - 0x61 + 1
                )
            last_dash = False
        elif b == 0x20 or b == 0x09 or b == 0x2D or b == 0x5F:
            if not last_dash:
                out += "-"
                last_dash = True
    if out.byte_length() > 0 and out.as_bytes()[out.byte_length() - 1] == 0x2D:
        out = _sub(out, 0, out.byte_length() - 1)
    return out^


# ---------- lines ----------


def _split_lines(source: String) -> List[String]:
    var lines = List[String]()
    var bytes = source.as_bytes()
    var start = 0
    for i in range(len(bytes)):
        if bytes[i] == 0x0A:
            var end = i
            if end > start and bytes[end - 1] == 0x0D:
                end -= 1
            lines.append(String(StringSlice(unsafe_from_utf8=bytes[start:end])))
            start = i + 1
    if start < len(bytes):
        lines.append(
            String(StringSlice(unsafe_from_utf8=bytes[start : len(bytes)]))
        )
    elif len(lines) == 0:
        lines.append(String())
    return lines^


def _leading_spaces(line: String) -> Int:
    """Indent width in columns, expanding tabs to 4-stops."""
    var bytes = line.as_bytes()
    var col = 0
    for i in range(len(bytes)):
        if bytes[i] == 0x20:
            col += 1
        elif bytes[i] == 0x09:
            col += 4 - (col % 4)
        else:
            break
    return col


def _column_at(line: String, byte_idx: Int) -> Int:
    """Column of the byte at `byte_idx`, expanding tabs to 4-stops.
    Only used on prefixes of spaces, tabs, and single marker bytes, so
    counting one column per other byte is exact there."""
    var bytes = line.as_bytes()
    var col = 0
    var stop = byte_idx
    if stop > len(bytes):
        stop = len(bytes)
    for i in range(stop):
        if bytes[i] == 0x09:
            col += 4 - (col % 4)
        else:
            col += 1
    return col


def _content_after(
    line: String, start_byte: Int, start_col: Int, target_col: Int
) -> String:
    """The text of `line` from the point where column `target_col` is
    reached, walking whitespace from byte `start_byte` (which sits at
    column `start_col`). A tab straddling the target contributes its
    remaining columns as spaces, and tabs inside the remaining leading
    whitespace run expand at their true width — so the result obeys
    leading_spaces(result) == leading_spaces(line) - target_col.
    Consumption stops at the first non-whitespace byte: columns inside
    content are never invented, and content tabs stay literal."""
    var bytes = line.as_bytes()
    var n = len(bytes)
    var out = String()
    var col = start_col
    var i = start_byte
    while i < n and col < target_col:
        var b = bytes[i]
        if b == 0x20:
            col += 1
            i += 1
        elif b == 0x09:
            var width = 4 - (col % 4)
            if col + width <= target_col:
                col += width
                i += 1
            else:
                for _ in range(col + width - target_col):
                    out += " "
                # The walk continues at the tab's TRUE end column, so
                # later tabs in the run expand at their true width.
                col = col + width
                i += 1
                break
        else:
            break
    while i < n:
        var b = bytes[i]
        if b == 0x20:
            out += " "
            col += 1
            i += 1
        elif b == 0x09:
            var width = 4 - (col % 4)
            for _ in range(width):
                out += " "
            col += width
            i += 1
        else:
            break
    out += _sub(line, i, n)
    return out^


def _strip_columns(line: String, cols: Int) -> String:
    """Remove `cols` columns of indentation (see _content_after)."""
    return _content_after(line, 0, 0, cols)


def _lstrip_blanks(line: String) -> String:
    """A line's content with all leading blanks removed (paragraph text
    starts at the first non-blank, however deep the indent)."""
    return _content_after(line, 0, 0, 1 << 30)


def _strip_columns_raw(line: String, cols: Int) -> String:
    """Remove `cols` columns of indentation for terminal code content:
    only a tab straddling the boundary is materialized (as its
    remaining spaces); every other byte, tabs included, stays literal,
    exactly as the reference renderers emit code content."""
    var bytes = line.as_bytes()
    var col = 0
    var i = 0
    while i < len(bytes) and col < cols:
        if bytes[i] == 0x20:
            col += 1
            i += 1
        elif bytes[i] == 0x09:
            var width = 4 - (col % 4)
            if col + width <= cols:
                col += width
                i += 1
            else:
                var rest = String()
                for _ in range(col + width - cols):
                    rest += " "
                return rest + _sub(line, i + 1, len(bytes))
        else:
            break
    return _sub(line, i, len(bytes))


def _is_blank(line: String) -> Bool:
    for b in line.as_bytes():
        if not _is_space(b):
            return False
    return True


def _expand_tabs(line: String) -> String:
    if line.find("\t") == -1:
        return line.copy()
    var bytes = line.as_bytes()
    var out = String()
    var col = 0
    for i in range(len(bytes)):
        if bytes[i] == 0x09:
            var n = 4 - (col % 4)
            out += _sub("    ", 0, n)
            col += n
        else:
            out += String(StringSlice(unsafe_from_utf8=bytes[i : i + 1]))
            col += 1
    return out^


# ---------- references and footnotes ----------


struct RefStore(Copyable, Movable):
    var labels: List[String]
    var defs: List[RefDef]
    var fn_labels: List[String]
    var fn_texts: List[String]
    var fn_used: List[String]
    var fn_numbers: List[Int]

    def __init__(out self):
        self.labels = List[String]()
        self.defs = List[RefDef]()
        self.fn_labels = List[String]()
        self.fn_texts = List[String]()
        self.fn_used = List[String]()
        self.fn_numbers = List[Int]()

    def lookup(self, label: String) -> Int:
        var norm = normalize_label(label)
        for i in range(len(self.labels)):
            if self.labels[i] == norm:
                return i
        return -1

    def footnote_index(self, label: String) -> Int:
        for i in range(len(self.fn_labels)):
            if self.fn_labels[i] == label:
                return i
        return -1

    def footnote_number(mut self, label: String) -> Int:
        for i in range(len(self.fn_used)):
            if self.fn_used[i] == label:
                return self.fn_numbers[i]
        var n = len(self.fn_used) + 1
        self.fn_used.append(label.copy())
        self.fn_numbers.append(n)
        return n


def _unescape_backslash(s: String) -> String:
    """Resolve backslash escapes of punctuation (used for link
    destinations, titles, and fence info strings)."""
    var bytes = s.as_bytes()
    var out = String()
    var i = 0
    while i < len(bytes):
        if bytes[i] == 0x5C and i + 1 < len(bytes) and _is_punct(bytes[i + 1]):
            out += String(StringSlice(unsafe_from_utf8=bytes[i + 1 : i + 2]))
            i += 2
            continue
        out += String(StringSlice(unsafe_from_utf8=bytes[i : i + 1]))
        i += 1
    return out^


def _decode_entities(s: String) -> String:
    """Decode named/numeric character references (link destinations and
    titles are entity-decoded before use)."""
    if s.find("&") == -1:
        return s.copy()
    var bytes = s.as_bytes()
    var out = String()
    var i = 0
    while i < len(bytes):
        if bytes[i] == 0x26:
            var semi = s.find(";", i)
            if semi != -1 and semi - i <= 34 and semi > i + 1:
                var body = _sub(s, i + 1, semi)
                if body.startswith("#"):
                    var num = _sub(body, 1, body.byte_length())
                    var cp = 0
                    var ok = num.byte_length() > 0
                    if num.startswith("x") or num.startswith("X"):
                        var hexpart = _sub(num, 1, num.byte_length())
                        if hexpart.byte_length() == 0:
                            ok = False
                        for hb in hexpart.as_bytes():
                            if UInt8(0x30) <= hb and hb <= UInt8(0x39):
                                cp = cp * 16 + Int(hb - 0x30)
                            elif UInt8(0x61) <= hb and hb <= UInt8(0x66):
                                cp = cp * 16 + Int(hb - 0x61) + 10
                            elif UInt8(0x41) <= hb and hb <= UInt8(0x46):
                                cp = cp * 16 + Int(hb - 0x41) + 10
                            else:
                                ok = False
                    else:
                        for db in num.as_bytes():
                            if UInt8(0x30) <= db and db <= UInt8(0x39):
                                cp = cp * 10 + Int(db - 0x30)
                            else:
                                ok = False
                    if ok and cp <= 0x10FFFF:
                        out += _decode_codepoint(cp)
                        i = semi + 1
                        continue
                else:
                    var val = _entity_value(body)
                    if val != "":
                        out += val
                        i = semi + 1
                        continue
        out += String(StringSlice(unsafe_from_utf8=bytes[i : i + 1]))
        i += 1
    return out^


def _skip_link_ws(s: String, i: Int) -> Tuple[Int, Bool]:
    """Skip the whitespace allowed between inline-link components:
    spaces and tabs, plus at most one line ending (itself followed by
    spaces and tabs). A second line ending is a blank line, which the
    grammar does not allow between components."""
    var bytes = s.as_bytes()
    var n = len(bytes)
    var j = i
    while j < n and (bytes[j] == 0x20 or bytes[j] == 0x09):
        j += 1
    if j < n and bytes[j] == 0x0D and j + 1 < n and bytes[j + 1] == 0x0A:
        j += 1
    if j < n and bytes[j] == 0x0A:
        j += 1
        while j < n and (bytes[j] == 0x20 or bytes[j] == 0x09):
            j += 1
        if j < n and bytes[j] == 0x0D and j + 1 < n and bytes[j + 1] == 0x0A:
            j += 1
        if j < n and bytes[j] == 0x0A:
            return (j, False)
    return (j, True)


def _parse_dest(s: String, i: Int) -> Tuple[Bool, String, Int]:
    """Parse a link destination at `i`: a pointy <...> form (escape
    pairs consumed atomically; unescaped < or a line ending fails) or
    a bare form (non-space, non-control characters with balanced
    unescaped parentheses). Returns (ok, dest, index past it)."""
    var bytes = s.as_bytes()
    var n = len(bytes)
    if i < n and bytes[i] == 0x3C:
        var j = i + 1
        while j < n:
            var b = bytes[j]
            if b == 0x5C and j + 1 < n and _is_punct(bytes[j + 1]):
                j += 2
                continue
            if b == 0x3E:
                return (True, _sub(s, i + 1, j), j + 1)
            if b == 0x3C or b == 0x0A or b == 0x0D:
                return (False, String(), i)
            j += 1
        return (False, String(), i)
    var depth = 0
    var j = i
    while j < n:
        var b = bytes[j]
        if b == 0x5C and j + 1 < n and _is_punct(bytes[j + 1]):
            j += 2
            continue
        if b <= UInt8(0x20):
            break
        if b == 0x28:
            depth += 1
        elif b == 0x29:
            if depth == 0:
                break
            depth -= 1
        j += 1
    if depth != 0:
        return (False, String(), i)
    return (True, _sub(s, i, j), j)


def _parse_link_title(s: String, i: Int) -> Tuple[Bool, String, Int]:
    """Parse a link title at `i` ("...", '...', or (...); a paren
    title may not contain an unescaped '('). May span lines.
    Returns (ok, title, index past the closer)."""
    var bytes = s.as_bytes()
    var n = len(bytes)
    if i >= n:
        return (False, String(), i)
    var q = bytes[i]
    if q != 0x22 and q != 0x27 and q != 0x28:
        return (False, String(), i)
    var close: UInt8 = 0x29 if q == 0x28 else q
    var j = i + 1
    while j < n:
        var b = bytes[j]
        if b == 0x5C and j + 1 < n and _is_punct(bytes[j + 1]):
            j += 2
            continue
        if q == 0x28 and b == 0x28:
            return (False, String(), i)
        if b == close:
            return (True, _sub(s, i + 1, j), j + 1)
        j += 1
    return (False, String(), i)


def _parse_link_dest_title(
    s: String, start: Int
) -> Tuple[Bool, String, String, Int]:
    """Parse `(dest "title")` beginning at the '(' at `start`.
    Returns (ok, dest, title, index just past ')')."""
    var bytes = s.as_bytes()
    var n = len(bytes)
    var skipped = _skip_link_ws(s, start + 1)
    var i = skipped[0]
    if not skipped[1]:
        return (False, String(), String(), start)
    var dest_parsed = _parse_dest(s, i)
    if not dest_parsed[0]:
        return (False, String(), String(), start)
    var dest = dest_parsed[1]
    i = dest_parsed[2]
    var before_ws = i
    skipped = _skip_link_ws(s, i)
    i = skipped[0]
    if not skipped[1]:
        return (False, String(), String(), start)
    var title = String()
    if i < n and bytes[i] != 0x29:
        # A title must be separated from the destination by whitespace.
        if i == before_ws:
            return (False, String(), String(), start)
        var t = _parse_link_title(s, i)
        if not t[0]:
            return (False, String(), String(), start)
        title = t[1].copy()
        i = t[2]
        skipped = _skip_link_ws(s, i)
        i = skipped[0]
        if not skipped[1]:
            return (False, String(), String(), start)
    if i < n and bytes[i] == 0x29:
        return (True, dest^, title^, i + 1)
    return (False, String(), String(), start)


def _spnl(s: String, i: Int) -> Int:
    """Skip spaces and tabs, then at most one line ending and any
    spaces and tabs after it (the whitespace forms allowed inside a
    link reference definition)."""
    var bytes = s.as_bytes()
    var n = len(bytes)
    var j = i
    while j < n and (bytes[j] == 0x20 or bytes[j] == 0x09):
        j += 1
    if j < n and bytes[j] == 0x0D and j + 1 < n and bytes[j + 1] == 0x0A:
        j += 1
    if j < n and bytes[j] == 0x0A:
        j += 1
        while j < n and (bytes[j] == 0x20 or bytes[j] == 0x09):
            j += 1
    return j


def _parse_ref_def_text(s: String) -> Tuple[Bool, String, String, String, Int]:
    """Parse one link reference definition at the start of `s` (a
    paragraph chunk: lines joined by single newlines, no blank
    lines). The destination may sit on a following line and the
    title on the line after that; after the destination and the
    optional title, the rest of the line must be blank, or the whole
    thing is not a definition.
    Returns (ok, label, dest, title, chars consumed incl. the final
    line ending when present)."""
    var bytes = s.as_bytes()
    var n = len(bytes)
    var i = 0
    while i < n and bytes[i] == 0x20 and i < 4:
        i += 1
    if i >= n or bytes[i] != 0x5B:
        return (False, String(), String(), String(), 0)
    var lend = _scan_ref_label(s, i + 1)
    if lend == -1:
        return (False, String(), String(), String(), 0)
    var label = _sub(s, i + 1, lend)
    if normalize_label(label) == "":
        return (False, String(), String(), String(), 0)
    i = lend + 1
    if i >= n or bytes[i] != 0x3A:
        return (False, String(), String(), String(), 0)
    i = _spnl(s, i + 1)
    if i >= n:
        return (False, String(), String(), String(), 0)
    var dp = _parse_dest(s, i)
    if not dp[0]:
        return (False, String(), String(), String(), 0)
    if dp[1] == "" and bytes[i] != 0x3C:
        return (False, String(), String(), String(), 0)  # no destination
    var dest = dp[1]
    i = dp[2]
    var title = String()
    var def_end = -1
    # A title must be separated from the destination by whitespace
    # (spaces, tabs, or up to one line ending inside the spnl). It is
    # part of the definition only if nothing but blanks follows it on
    # its line; otherwise the definition ends at the destination and
    # the destination's own line must end there.
    var after_ws = _spnl(s, i)
    if after_ws > i and after_ws < n and (
        bytes[after_ws] == 0x22
        or bytes[after_ws] == 0x27
        or bytes[after_ws] == 0x28
    ):
        var tp = _parse_link_title(s, after_ws)
        if tp[0]:
            var k = tp[2]
            while k < n and (bytes[k] == 0x20 or bytes[k] == 0x09):
                k += 1
            if k >= n:
                title = tp[1].copy()
                def_end = k
            elif bytes[k] == 0x0A:
                title = tp[1].copy()
                def_end = k + 1
            elif (
                bytes[k] == 0x0D
                and k + 1 < n
                and bytes[k + 1] == 0x0A
            ):
                title = tp[1].copy()
                def_end = k + 2
    if def_end == -1:
        var k = i
        while k < n and (bytes[k] == 0x20 or bytes[k] == 0x09):
            k += 1
        if k >= n:
            def_end = k
        elif bytes[k] == 0x0A:
            def_end = k + 1
        elif bytes[k] == 0x0D and k + 1 < n and bytes[k + 1] == 0x0A:
            def_end = k + 2
    if def_end == -1:
        return (False, String(), String(), String(), 0)
    return (True, label^, dest^, title^, def_end)


def _bq_strip(line: String) -> Tuple[Int, String]:
    """Strip blockquote prefixes (up to 3 spaces, '>', one optional
    space each). Returns (prefix count, remaining text)."""
    var bytes = line.as_bytes()
    var pos = 0
    var count = 0
    while True:
        var p = pos
        var spaces = 0
        while p < len(bytes) and bytes[p] == 0x20 and spaces < 3:
            p += 1
            spaces += 1
        if p < len(bytes) and bytes[p] == 0x3E:
            p += 1
            if p < len(bytes) and bytes[p] == 0x20:
                p += 1
            count += 1
            pos = p
        else:
            break
    return (count, _sub(line, pos, line.byte_length()))


def _first_nonspace_byte(line: String) -> Int:
    var bytes = line.as_bytes()
    var i = 0
    while i < len(bytes) and bytes[i] == 0x20:
        i += 1
    if i >= len(bytes):
        return -1
    return Int(bytes[i])


def _lines_spanned(text: String, chars: Int) -> Int:
    """How many joined-text lines the first `chars` characters span."""
    var bytes = text.as_bytes()
    var count = 0
    var upto = chars if chars < len(bytes) else len(bytes)
    for k in range(upto):
        if bytes[k] == 0x0A:
            count += 1
    if chars >= len(bytes):
        return count + 1
    return count


def _def_gate(
    lines: List[String], consumed: List[Bool], idx: Int, last_def_end: Int
) -> Bool:
    """A definition may only start a block: at the document start,
    after a blank line, after another definition, or after a leaf
    block line (heading, thematic break, fence) — never inside a
    paragraph."""
    if idx == 0:
        return True
    if consumed[idx - 1] or last_def_end == idx - 1:
        return True
    var prev = lines[idx - 1]
    if _is_blank(prev) or consumed[idx - 1]:
        return True
    if _atx_heading(prev)[0] or _is_thematic_break(prev):
        return True
    if _fence_start(prev)[0]:
        return True
    return False


def _collect_refs(
    lines: List[String],
) -> Tuple[RefStore, List[Bool]]:
    """Pre-pass: record link/footnote definitions and mark their
    lines consumed. Definitions may span lines (destination or
    title on a following line) and may live inside blockquotes
    (registered there for forward references; the block renderer
    consumes them when it recurses). A definition line inside a
    fenced code block is content, not a definition."""
    var refs = RefStore()
    var consumed = List[Bool]()
    for _ in range(len(lines)):
        consumed.append(False)
    var in_fence = False
    var fence_char: UInt8 = 0x60
    var fence_len = 0
    var last_def_end = -1
    var idx = 0
    while idx < len(lines):
        var line = lines[idx]
        var bytes = line.as_bytes()
        var indent = _leading_spaces(line)
        var pos = 0
        while pos < len(bytes) and bytes[pos] == 0x20:
            pos += 1
        if pos < len(bytes) and (bytes[pos] == 0x60 or bytes[pos] == 0x7E):
            var run = 0
            var p2 = pos
            while p2 < len(bytes) and bytes[p2] == bytes[pos]:
                run += 1
                p2 += 1
            if run >= 3 and indent < 4:
                if not in_fence:
                    in_fence = True
                    fence_char = bytes[pos]
                    fence_len = run
                elif bytes[pos] == fence_char and run >= fence_len:
                    in_fence = False
                idx += 1
                continue
        if in_fence or indent >= 4:
            idx += 1
            continue
        if line.startswith("[^"):
            var close = line.find("]:")
            if close > 2:
                var label = _sub(line, 2, close)
                refs.fn_labels.append(label)
                refs.fn_texts.append(
                    String(_sub(line, close + 2, line.byte_length()).strip())
                )
                consumed[idx] = True
                idx += 1
                continue
        var stripped = _bq_strip(line)
        var pc = stripped[0]
        var first = _first_nonspace_byte(stripped[1]) if pc > 0 else _first_nonspace_byte(line)
        if first == 0x5B and _def_gate(lines, consumed, idx, last_def_end):
            var texts = List[String]()
            texts.append(stripped[1] if pc > 0 else line)
            var cend = idx + 1
            while cend < len(lines):
                var nl = lines[cend]
                if pc > 0:
                    var ns = _bq_strip(nl)
                    if ns[0] != pc or _is_blank(ns[1]):
                        break
                    texts.append(ns[1].copy())
                else:
                    if _is_blank(nl):
                        break
                    texts.append(nl.copy())
                cend += 1
            var ctext = String()
            for k in range(len(texts)):
                if k > 0:
                    ctext += "\n"
                ctext += texts[k]
            var pd = _parse_ref_def_text(ctext)
            if pd[0]:
                if refs.lookup(pd[1]) == -1:
                    refs.labels.append(normalize_label(pd[1]))
                    refs.defs.append(RefDef(pd[2], pd[3]))
                var used = _lines_spanned(ctext, pd[4])
                last_def_end = idx + used - 1
                if pc == 0:
                    for k in range(used):
                        consumed[idx + k] = True
                idx += used
                continue
        idx += 1
    return (refs^, consumed^)


# ---------- block structure ----------


struct Ctx(Copyable, Movable):
    var refs: RefStore
    var headings: List[Heading]
    var used_ids: List[String]
    var with_ids: Bool
    var site: Bool

    def __init__(out self, refs: RefStore, site: Bool = False):
        self.refs = refs.copy()
        self.headings = List[Heading]()
        self.used_ids = List[String]()
        self.with_ids = site
        self.site = site

    def unique_id(mut self, text: String) -> String:
        var base = slugify(text)
        var seen = 0
        for ref u in self.used_ids:
            if u == base:
                seen += 1
        # Count existing suffixed variants too: keep it simple and correct
        # for the common sequential case.
        var candidate = base.copy()
        if seen > 0:
            candidate = base + "-" + String(seen)
            var k = seen
            while True:
                var clash = False
                for ref u in self.used_ids:
                    if u == candidate:
                        clash = True
                if not clash:
                    break
                k += 1
                candidate = base + "-" + String(k)
        self.used_ids.append(candidate.copy())
        return candidate^


def _atx_heading(line: String) -> Tuple[Bool, Int, String]:
    var bytes = line.as_bytes()
    var n = len(bytes)
    var i = 0
    while i < n and bytes[i] == 0x20 and i < 3:
        i += 1
    if i >= 4 and n > 0:
        return (False, 0, String())
    var level = 0
    while i < n and bytes[i] == 0x23:
        level += 1
        i += 1
    if level == 0 or level > 6:
        return (False, 0, String())
    if i < n and not _is_space(bytes[i]):
        return (False, 0, String())
    var content = String(_sub(line, i, n).strip())
    # Strip an optional closing run of #s preceded by a space.
    var cb = content.as_bytes()
    var end = len(cb)
    var j = end
    while j > 0 and cb[j - 1] == 0x23:
        j -= 1
    if j < end and j > 0 and _is_space(cb[j - 1]):
        content = String(_sub(content, 0, j).strip())
    elif j == 0 and end > 0:
        content = String()
    return (True, level, content^)


def _fence_start(line: String) -> Tuple[Bool, UInt8, Int, String]:
    var bytes = line.as_bytes()
    var n = len(bytes)
    var i = 0
    while i < n and bytes[i] == 0x20 and i < 3:
        i += 1
    if i >= n:
        return (False, UInt8(0), 0, String())
    var ch = bytes[i]
    if ch != 0x60 and ch != 0x7E:
        return (False, UInt8(0), 0, String())
    var run = 0
    while i < n and bytes[i] == ch:
        run += 1
        i += 1
    if run < 3:
        return (False, UInt8(0), 0, String())
    var info = String(_sub(line, i, n).strip())
    if ch == 0x60 and info.find("`") != -1:
        return (False, UInt8(0), 0, String())
    return (True, ch, run, info^)


def _is_thematic_break(line: String) -> Bool:
    var bytes = line.as_bytes()
    var ch: UInt8 = 0
    var count = 0
    for i in range(len(bytes)):
        var b = bytes[i]
        if b == 0x20 or b == 0x09:
            continue
        if b != 0x2D and b != 0x2A and b != 0x5F:
            return False
        if ch == 0:
            ch = b
        elif b != ch:
            return False
        count += 1
    return count >= 3 and _leading_spaces(line) < 4


def _setext_level(line: String) -> Int:
    """A setext underline is a run of = (level 1) or - (level 2) with up
    to 3 leading spaces and nothing but trailing spaces/tabs after the
    run — no spaces inside the run."""
    var bytes = line.as_bytes()
    var n = len(bytes)
    if n == 0 or _leading_spaces(line) >= 4:
        return 0
    var i = _first_nonspace(line)
    if i >= n:
        return 0
    var ch = bytes[i]
    if ch != 0x3D and ch != 0x2D:
        return 0
    var j = i
    while j < n and bytes[j] == ch:
        j += 1
    while j < n:
        if bytes[j] != 0x20 and bytes[j] != 0x09:
            return 0
        j += 1
    return 1 if ch == 0x3D else 2


def _first_nonspace(line: String) -> Int:
    var bytes = line.as_bytes()
    var i = 0
    while i < len(bytes) and bytes[i] == 0x20:
        i += 1
    return i


struct ListMarker(Copyable, Movable):
    var ok: Bool
    var ordered: Bool
    var number: Int
    var bullet: UInt8  # bullet char, or the ordered delimiter (. or ))
    var indent: Int  # columns of indentation before the marker
    var content_col: Int  # column where item content starts
    var end_byte: Int  # byte index just past the marker
    var end_col: Int  # column just past the marker
    var blank: Bool  # nothing but whitespace follows the marker

    def __init__(out self):
        self.ok = False
        self.ordered = False
        self.number = 0
        self.bullet = 0
        self.indent = 0
        self.content_col = 0
        self.end_byte = 0
        self.end_col = 0
        self.blank = False


def _finish_marker(line: String, mut m: ListMarker):
    """Compute the content column from the whitespace following the
    marker, counted in columns one at a time (tabs partially) exactly
    as the spec prescribes: 1-4 columns of following whitespace put the
    content at marker end + that many columns; 5 or more, or a blank
    remainder, put it at marker end + 1."""
    var bytes = line.as_bytes()
    var n = len(bytes)
    var col = m.end_col
    var j = m.end_byte
    var ws = 0
    while j < n and ws < 5:
        var b = bytes[j]
        if b == 0x20:
            ws += 1
            col += 1
            j += 1
        elif b == 0x09:
            var width = 4 - (col % 4)
            var step = width if width < 5 - ws else 5 - ws
            ws += step
            col += step
            if step == width:
                j += 1
            else:
                break
        else:
            break
    if j >= n:
        m.blank = True
        m.content_col = m.end_col + 1
    elif ws == 0:
        m.ok = False
    elif ws >= 5:
        m.content_col = m.end_col + 1
    else:
        m.content_col = m.end_col + ws


def _list_marker(line: String) -> ListMarker:
    var m = ListMarker()
    var bytes = line.as_bytes()
    var n = len(bytes)
    var indent = _leading_spaces(line)
    if indent >= 4:
        return m^
    var i = _first_nonspace(line)
    if i >= n:
        return m^
    var b = bytes[i]
    if b == 0x2D or b == 0x2B or b == 0x2A:
        m.ok = True
        m.ordered = False
        m.bullet = b
        m.indent = indent
        m.end_byte = i + 1
        m.end_col = indent + 1
        _finish_marker(line, m)
        return m^
    if _is_digit(b):
        var num = 0
        var digits = 0
        var j = i
        while j < n and _is_digit(bytes[j]) and digits <= 9:
            num = num * 10 + Int(bytes[j] - 0x30)
            digits += 1
            j += 1
        if digits == 0 or digits > 9 or j >= n:
            return m^
        if bytes[j] != 0x2E and bytes[j] != 0x29:
            return m^
        m.ok = True
        m.ordered = True
        m.number = num
        m.bullet = bytes[j]
        m.indent = indent
        m.end_byte = j + 1
        m.end_col = indent + digits + 1
        _finish_marker(line, m)
        return m^
    return m^


def _item_content(line: String, m: ListMarker) -> String:
    """The item's first content line: the text at the marker's content
    column, reached by walking columns from the marker's end."""
    if m.blank:
        return String()
    return _content_after(line, m.end_byte, m.end_col, m.content_col)


def _tag_name_at(s: String, pos: Int) -> Tuple[String, Int]:
    """Read a tag name at `pos` (letters, digits, hyphens), returned
    ASCII-lowercased with the index just past it; empty if none."""
    var bytes = s.as_bytes()
    var j = pos
    var name = String()
    while j < len(bytes) and (
        _is_alpha(bytes[j]) or _is_digit(bytes[j]) or bytes[j] == 0x2D
    ):
        name += String(
            StringSlice(unsafe_from_utf8=bytes[j : j + 1])
        ) if bytes[j] < 0x41 or bytes[j] > 0x5A else _sub(
            "abcdefghijklmnopqrstuvwxyz",
            Int(bytes[j]) - 0x41,
            Int(bytes[j]) - 0x41 + 1,
        )
        j += 1
    return (name^, j)


def _is_block_tag(name: String) -> Bool:
    """The type-6 HTML block tag list (lowercase names)."""
    comptime NAMES = (
        "|address|article|aside|base|basefont|blockquote|body|caption"
        "|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset"
        "|figcaption|figure|footer|form|frame|frameset|h1|h2|h3|h4|h5"
        "|h6|head|header|hr|html|iframe|legend|li|link|main|menu"
        "|menuitem|nav|noframes|ol|optgroup|option|p|param|search"
        "|section|summary|table|tbody|td|tfoot|th|thead|title|tr"
        "|track|ul|"
    )
    var haystack = String(NAMES)
    var target = String("|") + name + "|"
    var tlen = target.byte_length()
    for i in range(haystack.byte_length() - tlen + 1):
        if _sub(haystack, i, i + tlen) == target:
            return True
    return False


def _contains_fold(s: String, needle: String) -> Bool:
    """Whether `s` contains `needle` (lowercase ASCII) under ASCII
    case folding."""
    var sb = s.as_bytes()
    var nb = needle.as_bytes()
    if len(nb) == 0 or len(sb) < len(nb):
        return len(nb) == 0
    for i in range(len(sb) - len(nb) + 1):
        var ok = True
        for k in range(len(nb)):
            var c = Int(sb[i + k])
            if 0x41 <= c and c <= 0x5A:
                c = c + 0x20
            if c != Int(nb[k]):
                ok = False
                break
        if ok:
            return True
    return False


def _html_block_type(line: String) -> Int:
    """The CommonMark HTML block type a line starts (1-7), or 0.
    The line may carry up to three leading spaces."""
    var i = _first_nonspace(line)
    var bytes = line.as_bytes()
    var n = len(bytes)
    if _leading_spaces(line) > 3 or i >= n or bytes[i] != 0x3C:
        return 0
    var rest = _sub(line, i, n)
    if rest.startswith("<!--"):
        return 2
    if rest.startswith("<?"):
        return 3
    if rest.startswith("<![CDATA["):
        return 5
    if rest.startswith("<!"):
        if i + 2 < n and _is_alpha(bytes[i + 2]):
            return 4
        return 0
    var j = i + 1
    var closing = False
    if j < n and bytes[j] == 0x2F:
        closing = True
        j += 1
    var named = _tag_name_at(line, j)
    var name = named[0]
    var after = named[1]
    if name == "":
        return 0
    var raw_tag = (
        name == "pre" or name == "script" or name == "style" or name == "textarea"
    )
    if not closing and raw_tag:
        if after >= n or bytes[after] == 0x20 or bytes[after] == 0x09 or bytes[after] == 0x3E:
            return 1
    if _is_block_tag(name):
        if after >= n:
            return 6
        var b = bytes[after]
        if b == 0x20 or b == 0x09 or b == 0x3E:
            return 6
        if b == 0x2F and after + 1 < n and bytes[after + 1] == 0x3E:
            return 6
    var tag_end = _scan_tag(line, i)
    if tag_end != -1:
        var k = tag_end
        while k < n and (bytes[k] == 0x20 or bytes[k] == 0x09):
            k += 1
        if k >= n:
            if not closing and raw_tag:
                return 0
            return 7
    return 0


def _html_end_line(line: String, block_type: Int) -> Bool:
    """Whether a line meets the end condition of an HTML block of
    types 1-5."""
    if block_type == 1:
        return (
            _contains_fold(line, "</pre>")
            or _contains_fold(line, "</script>")
            or _contains_fold(line, "</style>")
            or _contains_fold(line, "</textarea>")
        )
    if block_type == 2:
        return line.find("-->") != -1
    if block_type == 3:
        return line.find("?>") != -1
    if block_type == 4:
        return line.find(">") != -1
    if block_type == 5:
        return line.find("]]>") != -1
    return False
def _block_starts(line: String, consumed: Bool) -> Bool:
    if consumed or _is_blank(line):
        return True
    if _fence_start(line)[0] or _atx_heading(line)[0]:
        return True
    if _is_thematic_break(line):
        return True
    var ht = _html_block_type(line)
    if 1 <= ht and ht <= 6:
        return True
    var bm = _list_marker(line)
    if bm.ok and not bm.blank:
        # An empty item cannot interrupt a paragraph.
        return True
    var i = _first_nonspace(line)
    return i < line.byte_length() and line.as_bytes()[i] == 0x3E


def _split_row(line: String) -> List[String]:
    """Split a table row on unescaped pipes (pipes inside code spans are
    literal). A leading/trailing pipe is structural, not a cell."""
    var bytes = line.as_bytes()
    var n = len(bytes)
    var cells = List[String]()
    var cur = String()
    var in_code = 0
    var i = 0
    while i < n:
        var b = bytes[i]
        if b == 0x5C and i + 1 < n and bytes[i + 1] == 0x7C:
            cur += "|"
            i += 2
            continue
        if b == 0x60:
            var run = 0
            while i < n and bytes[i] == 0x60:
                run += 1
                i += 1
            for _ in range(run):
                cur += "`"
            if in_code == 0:
                in_code = run
            elif in_code == run:
                in_code = 0
            continue
        if b == 0x7C and in_code == 0:
            cells.append(cur.copy())
            cur = String()
            i += 1
            continue
        cur += String(StringSlice(unsafe_from_utf8=bytes[i : i + 1]))
        i += 1
    cells.append(cur.copy())
    # Trim structural edge cells.
    if len(cells) > 0 and String(cells[0].strip()) == "":
        _ = cells.pop(0)
    if len(cells) > 0 and String(cells[len(cells) - 1].strip()) == "":
        _ = cells.pop()
    var trimmed = List[String]()
    for ref c in cells:
        trimmed.append(String(c.strip()))
    return trimmed^


def _table_aligns(delim: List[String]) -> Tuple[Bool, List[Int]]:
    """Alignment per column: 0 none, 1 left, 2 center, 3 right."""
    var aligns = List[Int]()
    for ref cell in delim:
        var s = String(cell.strip())
        var sb = s.as_bytes()
        if len(sb) == 0:
            return (False, List[Int]())
        var left = sb[0] == 0x3A
        var right = sb[len(sb) - 1] == 0x3A
        for i in range(len(sb)):
            if sb[i] != 0x2D and sb[i] != 0x3A:
                return (False, List[Int]())
        if left and right:
            aligns.append(2)
        elif left:
            aligns.append(1)
        elif right:
            aligns.append(3)
        else:
            aligns.append(0)
    return (True, aligns^)


def _align_attr(a: Int) -> String:
    # The reference renderer (Zola) expresses alignment as an inline
    # text-align style; Hearth matches it.
    if a == 1:
        return String(' style="text-align: left"')
    if a == 2:
        return String(' style="text-align: center"')
    if a == 3:
        return String(' style="text-align: right"')
    return String()


def _render_table(
    lines: List[String], i: Int, hi: Int, mut ctx: Ctx
) -> Tuple[String, Int]:
    var header = _split_row(lines[i])
    var delim = _split_row(lines[i + 1])
    var parsed = _table_aligns(delim)
    var aligns = parsed[1].copy()
    var cols = len(header)
    var out = String("<table>\n<thead>\n<tr>\n")
    for c in range(cols):
        out += "<th" + _align_attr(aligns[c]) + ">"
        out += render_inline(header[c], ctx)
        out += "</th>\n"
    out += "</tr>\n</thead>\n"
    var rows = List[List[String]]()
    var j = i + 2
    while j < hi and not _is_blank(lines[j]):
        rows.append(_split_row(lines[j]))
        j += 1
    if len(rows) > 0:
        out += "<tbody>\n"
        for r in range(len(rows)):
            out += "<tr>\n"
            for c in range(cols):
                var cell = String()
                if c < len(rows[r]):
                    cell = rows[r][c].copy()
                out += "<td" + _align_attr(aligns[c]) + ">"
                out += render_inline(cell, ctx)
                out += "</td>\n"
            out += "</tr>\n"
        out += "</tbody>\n"
    out += "</table>\n"
    return (out^, j)


def _leaf_is_paragraph(line: String) -> Bool:
    """Whether `line`, as a frame's newest line, leaves a paragraph
    as the open leaf block — so a following line may continue it
    lazily. Blank lines and every block start close the paragraph."""
    if _is_blank(line) or _leading_spaces(line) >= 4:
        return False
    if _fence_start(line)[0] or _atx_heading(line)[0]:
        return False
    if _is_thematic_break(line) or _html_block_type(line) > 0:
        return False
    if _list_marker(line).ok:
        return False
    var p = _first_nonspace(line)
    if p < line.byte_length() and line.as_bytes()[p] == 0x3E:
        return False
    return True


def _render_list(
    lines: List[String],
    start: Int,
    hi: Int,
    consumed: List[Bool],
    mut ctx: Ctx,
    depth: Int,
) -> Tuple[String, Int]:
    var first = _list_marker(lines[start])
    var items = List[List[String]]()
    var loose = False
    var j = start
    var content_col = first.content_col
    while j < hi:
        if consumed[j]:
            break
        var line = lines[j]
        # A thematic break at the list's own level ends the list
        # (it takes precedence over reading the line as an item).
        if (
            j > start
            and _is_thematic_break(line)
            and _leading_spaces(line) < content_col
        ):
            break
        var m = _list_marker(line)
        var same_list = (
            m.ok
            and m.indent == first.indent
            and m.ordered == first.ordered
            and (first.ordered and m.bullet == first.bullet or not first.ordered and m.bullet == first.bullet)
        )
        if same_list and len(items) > 0 or (same_list and j == start):
            content_col = m.content_col
            var content = _item_content(line, m)
            var item = List[String]()
            item.append(content^)
            items.append(item^)
            j += 1
            continue
        if _is_blank(line):
            # Look ahead: the list continues if the next non-blank line is
            # a new item or an indented continuation.
            var k = j + 1
            while k < hi and _is_blank(lines[k]) and not consumed[k]:
                k += 1
            if k < hi and not consumed[k]:
                var m2 = _list_marker(lines[k])
                var continues = (m2.ok and m2.indent == first.indent) or (
                    _leading_spaces(lines[k]) >= content_col
                )
                if continues:
                    loose = True
                    if len(items) > 0:
                        items[len(items) - 1].append(String())
                    j = k
                    continue
            break
        if len(items) > 0 and _leading_spaces(line) >= content_col:
            items[len(items) - 1].append(_strip_columns(line, content_col))
            j += 1
            continue
        if len(items) > 0 and not _block_starts(line, False):
            items[len(items) - 1].append(String(line.strip()))
            j += 1
            continue
        break
    var out = String()
    if first.ordered:
        if first.number != 1:
            out += '<ol start="' + String(first.number) + '">\n'
        else:
            out += "<ol>\n"
    else:
        out += "<ul>\n"
    var no_consume = List[Bool]()
    for item in items:
        for _ in range(len(item)):
            no_consume.append(False)
        var inner = render_blocks(item, 0, len(item), no_consume, ctx, depth + 1)
        no_consume.clear()
        var single_para = (
            inner.startswith("<p>")
            and inner.endswith("</p>\n")
            and inner.find("<p>", 3) == -1
        )
        if inner == "":
            out += "<li></li>\n"
        elif not loose and single_para:
            # Tight single-paragraph item: bare inline content, no
            # trailing newline inside the item.
            out += "<li>" + _sub(inner, 3, inner.byte_length() - 5) + "</li>\n"
        else:
            out += "<li>\n" + inner + "</li>\n"
    out += "</ol>\n" if first.ordered else "</ul>\n"
    return (out^, j)


def _plain_text(html: String) -> String:
    var out = String()
    var bytes = html.as_bytes()
    var i = 0
    while i < len(bytes):
        if bytes[i] == 0x3C:
            var tag_start = i
            while i < len(bytes) and bytes[i] != 0x3E:
                i += 1
            i += 1
            # An image contributes its alt text (attribute-escaped in
            # the markup; the final replace pass unescapes it).
            if html.startswith("<img", tag_start):
                var alt_at = html.find('alt="', tag_start)
                if alt_at != -1 and alt_at < i:
                    var vend = html.find('"', alt_at + 5)
                    if vend != -1 and vend < i:
                        out += _sub(html, alt_at + 5, vend)
            continue
        out += String(StringSlice(unsafe_from_utf8=bytes[i : i + 1]))
        i += 1
    return out.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"')


def render_blocks(
    lines: List[String],
    lo: Int,
    hi: Int,
    consumed: List[Bool],
    mut ctx: Ctx,
    depth: Int,
) -> String:
    var out = String()
    if depth > MAX_BLOCK_DEPTH:
        return out^
    var i = lo
    while i < hi:
        if consumed[i] or _is_blank(lines[i]):
            i += 1
            continue
        var line = lines[i]
        # A reference definition at a block boundary registers and
        # renders nothing. The pre-pass already collected top-level
        # definitions (first wins); this pass catches the ones inside
        # containers and keeps container content consistent.
        if _leading_spaces(line) < 4 and _first_nonspace_byte(line) == 0x5B:
            var cend = i
            while cend < hi and not _is_blank(lines[cend]):
                cend += 1
            var ctext = String()
            for k in range(i, cend):
                if k > i:
                    ctext += "\n"
                ctext += lines[k]
            var pd = _parse_ref_def_text(ctext)
            if pd[0]:
                if ctx.refs.lookup(pd[1]) == -1:
                    ctx.refs.labels.append(normalize_label(pd[1]))
                    ctx.refs.defs.append(RefDef(pd[2], pd[3]))
                i += _lines_spanned(ctext, pd[4])
                continue
        # Fenced code.
        var fence = _fence_start(line)
        if fence[0]:
            var fence_indent = _leading_spaces(line)
            var j = i + 1
            var content = String()
            while j < hi:
                var f2 = lines[j].as_bytes()
                var run = 0
                var p = _first_nonspace(lines[j])
                while p < len(f2) and f2[p] == fence[1]:
                    run += 1
                    p += 1
                var rest = String(_sub(lines[j], p, len(f2)).strip())
                if run >= fence[2] and rest == "" and _leading_spaces(lines[j]) < 4:
                    break
                content += _strip_columns_raw(lines[j], fence_indent) + "\n"
                j += 1
            var info = fence[3]
            var first_word = _decode_entities(_unescape_backslash(String(info.split(" ")[0]))) if info != "" else String()
            out += "<pre><code"
            if first_word != "":
                if ctx.site:
                    out += ' data-lang="' + escape_attr(first_word) + '"'
                else:
                    out += ' class="language-' + escape_attr(first_word) + '"'
            out += ">" + escape_text(content) + "</code></pre>\n"
            i = j + 1 if j < hi else hi
            continue
        # ATX heading.
        var atx = _atx_heading(line)
        if atx[0]:
            var inner = render_inline(atx[2], ctx)
            var id = ctx.unique_id(_plain_text(inner))
            ctx.headings.append(Heading(atx[1], id, _plain_text(inner)))
            out += "<h" + String(atx[1])
            if ctx.with_ids:
                out += ' id="' + id + '"'
            out += ">" + inner
            out += "</h" + String(atx[1]) + ">\n"
            i += 1
            continue
        # Thematic break (before list/paragraph: `- - -` reads as break).
        if _is_thematic_break(line):
            out += "<hr />\n"
            i += 1
            continue
        # Blockquote.
        var qpos = _first_nonspace(line)
        if (
            _leading_spaces(line) < 4
            and qpos < line.byte_length()
            and line.as_bytes()[qpos] == 0x3E
        ):
            var inner_lines = List[String]()
            var inner_direct = List[Bool]()
            var para_open = False
            var j = i
            while j < hi and not consumed[j] and not _is_blank(lines[j]):
                var ql = lines[j]
                var qp = _first_nonspace(ql)
                if (
                    _leading_spaces(ql) < 4
                    and qp < ql.byte_length()
                    and ql.as_bytes()[qp] == 0x3E
                ):
                    var after = qp + 1
                    var stripped: String
                    if (
                        after < ql.byte_length()
                        and (
                            ql.as_bytes()[after] == 0x20
                            or ql.as_bytes()[after] == 0x09
                        )
                    ):
                        # The marker may be followed by one column of
                        # whitespace (a tab counts as one column here).
                        var acol = _column_at(ql, after)
                        stripped = _content_after(ql, after, acol, acol + 1)
                    else:
                        stripped = _sub(ql, after, ql.byte_length())
                    para_open = _leaf_is_paragraph(_bq_strip(stripped)[1])
                    inner_lines.append(stripped^)
                    inner_direct.append(True)
                    j += 1
                    continue
                if _block_starts(ql, False):
                    break
                if not para_open:
                    # Lazy continuation exists only for an open
                    # paragraph inside the quote.
                    break
                inner_lines.append(ql.copy())  # lazy continuation
                inner_direct.append(False)
                j += 1
            # A lazy setext underline cannot convert a paragraph whose
            # last line sits inside the quote: hand the underline back
            # to this frame.
            while len(inner_lines) >= 2:
                var last = len(inner_lines) - 1
                if (
                    not inner_direct[last]
                    and inner_direct[last - 1]
                    and _setext_level(inner_lines[last]) > 0
                ):
                    _ = inner_lines.pop()
                    _ = inner_direct.pop()
                    j -= 1
                else:
                    break
            var no_consume = List[Bool]()
            for _ in range(len(inner_lines)):
                no_consume.append(False)
            var inner = render_blocks(
                inner_lines, 0, len(inner_lines), no_consume, ctx, depth + 1
            )
            out += "<blockquote>\n" + inner + "</blockquote>\n"
            i = j
            continue
        # HTML block: types 1-5 run to their end-condition line
        # (blank lines included); types 6-7 end at a blank line.
        var html_type = _html_block_type(line)
        if html_type > 0:
            var j = i
            var raw = String()
            if html_type <= 5:
                while j < hi:
                    raw += lines[j] + "\n"
                    var done = _html_end_line(lines[j], html_type)
                    j += 1
                    if done:
                        break
            else:
                while j < hi and not _is_blank(lines[j]):
                    raw += lines[j] + "\n"
                    j += 1
            out += raw
            i = j
            continue
        # Indented code (only at a block boundary, which here is given:
        # paragraph continuation is claimed by the paragraph branch).
        if _leading_spaces(line) >= 4:
            var j = i
            var content = String()
            var pending = List[String]()
            while j < hi:
                if _is_blank(lines[j]):
                    # A whitespace-only line inside the block keeps
                    # whatever indentation survives the 4-column strip.
                    pending.append(_strip_columns_raw(lines[j], 4))
                    j += 1
                    continue
                if _leading_spaces(lines[j]) < 4:
                    break
                for ref p in pending:
                    content += p + "\n"
                pending.clear()
                content += _strip_columns_raw(lines[j], 4) + "\n"
                j += 1
            out += "<pre><code>" + escape_text(content) + "</code></pre>\n"
            i = j
            continue
        # Table: header line + delimiter line.
        if i + 1 < hi and not consumed[i + 1] and line.find("|") != -1:
            var parsed = _table_aligns(_split_row(lines[i + 1]))
            if parsed[0] and len(parsed[1]) == len(_split_row(line)):
                var t = _render_table(lines, i, hi, ctx)
                out += t[0]
                i = t[1]
                continue
        # List.
        var m = _list_marker(line)
        if m.ok:
            var l = _render_list(lines, i, hi, consumed, ctx, depth)
            out += l[0]
            i = l[1]
            continue
        # Paragraph (with setext-heading detection).
        var j = i
        var text = String()
        var setext = 0
        while j < hi and not consumed[j] and not _is_blank(lines[j]):
            if j > i:
                var lvl = _setext_level(lines[j])
                if lvl > 0:
                    setext = lvl
                    j += 1
                    break
                if _block_starts(lines[j], False):
                    break
            if j > i:
                text += "\n"
            text += _lstrip_blanks(lines[j])
            j += 1
        # Trailing blanks of the paragraph's last line are not content.
        while text.byte_length() > 0:
            var last = text.as_bytes()[text.byte_length() - 1]
            if last == 0x20 or last == 0x09:
                text = _sub(text, 0, text.byte_length() - 1)
            else:
                break
        if setext > 0:
            var inner = render_inline(text, ctx)
            var id = ctx.unique_id(_plain_text(inner))
            ctx.headings.append(Heading(setext, id, _plain_text(inner)))
            out += "<h" + String(setext)
            if ctx.with_ids:
                out += ' id="' + id + '"'
            out += ">" + inner
            out += "</h" + String(setext) + ">\n"
        else:
            out += "<p>" + render_inline(text, ctx) + "</p>\n"
        i = j
    return out^


def render_markdown(source: String, site_extensions: Bool = False) raises -> MdResult:
    if source.byte_length() > MAX_INPUT_BYTES:
        raise Error("markdown: input exceeds size bound")
    var clean = source.replace("\x00", "�")
    var lines = _split_lines(clean)
    var collected = _collect_refs(lines)
    var ctx = Ctx(collected[0], site_extensions)
    var html = render_blocks(lines, 0, len(lines), collected[1], ctx, 0)
    if len(ctx.refs.fn_used) > 0:
        html += '<section class="footnotes" data-footnotes>\n<ol>\n'
        for idx in range(len(ctx.refs.fn_used)):
            var label = ctx.refs.fn_used[idx]
            var di = ctx.refs.footnote_index(label)
            var fn_html = String()
            if di >= 0:
                var fn_src = ctx.refs.fn_texts[di].copy()
                fn_html = render_inline(fn_src, ctx)
            html += '<li id="fn:' + label + '">\n<p>' + fn_html
            html += (
                ' <a href="#fnref:'
                + label
                + '" class="footnote-backref" data-footnote-backref aria-label="Back to reference '
                + label
                + '">↩</a></p>\n</li>\n'
            )
        html += "</ol>\n</section>\n"
    var result = MdResult()
    result.html = html^
    result.headings = ctx.headings.copy()
    return result^


def render_html(source: String) raises -> String:
    """Render Markdown to an HTML fragment (the corpus-gate entry point)."""
    return render_markdown(source).html


# ---------- inline ----------


def _entity_value(name: String) -> String:
    """The HTML5 named character references (semicolon forms;
    CommonMark does not recognize the legacy no-semicolon forms).
    Generated from the HTML5 entity list. Returns "" when the
    name is not a reference."""
    if name == "AElig":
        return "Æ"
    if name == "AMP":
        return "&"
    if name == "Aacute":
        return "Á"
    if name == "Abreve":
        return "Ă"
    if name == "Acirc":
        return "Â"
    if name == "Acy":
        return "А"
    if name == "Afr":
        return "𝔄"
    if name == "Agrave":
        return "À"
    if name == "Alpha":
        return "Α"
    if name == "Amacr":
        return "Ā"
    if name == "And":
        return "⩓"
    if name == "Aogon":
        return "Ą"
    if name == "Aopf":
        return "𝔸"
    if name == "ApplyFunction":
        return "⁡"
    if name == "Aring":
        return "Å"
    if name == "Ascr":
        return "𝒜"
    if name == "Assign":
        return "≔"
    if name == "Atilde":
        return "Ã"
    if name == "Auml":
        return "Ä"
    if name == "Backslash":
        return "∖"
    if name == "Barv":
        return "⫧"
    if name == "Barwed":
        return "⌆"
    if name == "Bcy":
        return "Б"
    if name == "Because":
        return "∵"
    if name == "Bernoullis":
        return "ℬ"
    if name == "Beta":
        return "Β"
    if name == "Bfr":
        return "𝔅"
    if name == "Bopf":
        return "𝔹"
    if name == "Breve":
        return "˘"
    if name == "Bscr":
        return "ℬ"
    if name == "Bumpeq":
        return "≎"
    if name == "CHcy":
        return "Ч"
    if name == "COPY":
        return "©"
    if name == "Cacute":
        return "Ć"
    if name == "Cap":
        return "⋒"
    if name == "CapitalDifferentialD":
        return "ⅅ"
    if name == "Cayleys":
        return "ℭ"
    if name == "Ccaron":
        return "Č"
    if name == "Ccedil":
        return "Ç"
    if name == "Ccirc":
        return "Ĉ"
    if name == "Cconint":
        return "∰"
    if name == "Cdot":
        return "Ċ"
    if name == "Cedilla":
        return "¸"
    if name == "CenterDot":
        return "·"
    if name == "Cfr":
        return "ℭ"
    if name == "Chi":
        return "Χ"
    if name == "CircleDot":
        return "⊙"
    if name == "CircleMinus":
        return "⊖"
    if name == "CirclePlus":
        return "⊕"
    if name == "CircleTimes":
        return "⊗"
    if name == "ClockwiseContourIntegral":
        return "∲"
    if name == "CloseCurlyDoubleQuote":
        return "”"
    if name == "CloseCurlyQuote":
        return "’"
    if name == "Colon":
        return "∷"
    if name == "Colone":
        return "⩴"
    if name == "Congruent":
        return "≡"
    if name == "Conint":
        return "∯"
    if name == "ContourIntegral":
        return "∮"
    if name == "Copf":
        return "ℂ"
    if name == "Coproduct":
        return "∐"
    if name == "CounterClockwiseContourIntegral":
        return "∳"
    if name == "Cross":
        return "⨯"
    if name == "Cscr":
        return "𝒞"
    if name == "Cup":
        return "⋓"
    if name == "CupCap":
        return "≍"
    if name == "DD":
        return "ⅅ"
    if name == "DDotrahd":
        return "⤑"
    if name == "DJcy":
        return "Ђ"
    if name == "DScy":
        return "Ѕ"
    if name == "DZcy":
        return "Џ"
    if name == "Dagger":
        return "‡"
    if name == "Darr":
        return "↡"
    if name == "Dashv":
        return "⫤"
    if name == "Dcaron":
        return "Ď"
    if name == "Dcy":
        return "Д"
    if name == "Del":
        return "∇"
    if name == "Delta":
        return "Δ"
    if name == "Dfr":
        return "𝔇"
    if name == "DiacriticalAcute":
        return "´"
    if name == "DiacriticalDot":
        return "˙"
    if name == "DiacriticalDoubleAcute":
        return "˝"
    if name == "DiacriticalGrave":
        return "`"
    if name == "DiacriticalTilde":
        return "˜"
    if name == "Diamond":
        return "⋄"
    if name == "DifferentialD":
        return "ⅆ"
    if name == "Dopf":
        return "𝔻"
    if name == "Dot":
        return "¨"
    if name == "DotDot":
        return "⃜"
    if name == "DotEqual":
        return "≐"
    if name == "DoubleContourIntegral":
        return "∯"
    if name == "DoubleDot":
        return "¨"
    if name == "DoubleDownArrow":
        return "⇓"
    if name == "DoubleLeftArrow":
        return "⇐"
    if name == "DoubleLeftRightArrow":
        return "⇔"
    if name == "DoubleLeftTee":
        return "⫤"
    if name == "DoubleLongLeftArrow":
        return "⟸"
    if name == "DoubleLongLeftRightArrow":
        return "⟺"
    if name == "DoubleLongRightArrow":
        return "⟹"
    if name == "DoubleRightArrow":
        return "⇒"
    if name == "DoubleRightTee":
        return "⊨"
    if name == "DoubleUpArrow":
        return "⇑"
    if name == "DoubleUpDownArrow":
        return "⇕"
    if name == "DoubleVerticalBar":
        return "∥"
    if name == "DownArrow":
        return "↓"
    if name == "DownArrowBar":
        return "⤓"
    if name == "DownArrowUpArrow":
        return "⇵"
    if name == "DownBreve":
        return "̑"
    if name == "DownLeftRightVector":
        return "⥐"
    if name == "DownLeftTeeVector":
        return "⥞"
    if name == "DownLeftVector":
        return "↽"
    if name == "DownLeftVectorBar":
        return "⥖"
    if name == "DownRightTeeVector":
        return "⥟"
    if name == "DownRightVector":
        return "⇁"
    if name == "DownRightVectorBar":
        return "⥗"
    if name == "DownTee":
        return "⊤"
    if name == "DownTeeArrow":
        return "↧"
    if name == "Downarrow":
        return "⇓"
    if name == "Dscr":
        return "𝒟"
    if name == "Dstrok":
        return "Đ"
    if name == "ENG":
        return "Ŋ"
    if name == "ETH":
        return "Ð"
    if name == "Eacute":
        return "É"
    if name == "Ecaron":
        return "Ě"
    if name == "Ecirc":
        return "Ê"
    if name == "Ecy":
        return "Э"
    if name == "Edot":
        return "Ė"
    if name == "Efr":
        return "𝔈"
    if name == "Egrave":
        return "È"
    if name == "Element":
        return "∈"
    if name == "Emacr":
        return "Ē"
    if name == "EmptySmallSquare":
        return "◻"
    if name == "EmptyVerySmallSquare":
        return "▫"
    if name == "Eogon":
        return "Ę"
    if name == "Eopf":
        return "𝔼"
    if name == "Epsilon":
        return "Ε"
    if name == "Equal":
        return "⩵"
    if name == "EqualTilde":
        return "≂"
    if name == "Equilibrium":
        return "⇌"
    if name == "Escr":
        return "ℰ"
    if name == "Esim":
        return "⩳"
    if name == "Eta":
        return "Η"
    if name == "Euml":
        return "Ë"
    if name == "Exists":
        return "∃"
    if name == "ExponentialE":
        return "ⅇ"
    if name == "Fcy":
        return "Ф"
    if name == "Ffr":
        return "𝔉"
    if name == "FilledSmallSquare":
        return "◼"
    if name == "FilledVerySmallSquare":
        return "▪"
    if name == "Fopf":
        return "𝔽"
    if name == "ForAll":
        return "∀"
    if name == "Fouriertrf":
        return "ℱ"
    if name == "Fscr":
        return "ℱ"
    if name == "GJcy":
        return "Ѓ"
    if name == "GT":
        return ">"
    if name == "Gamma":
        return "Γ"
    if name == "Gammad":
        return "Ϝ"
    if name == "Gbreve":
        return "Ğ"
    if name == "Gcedil":
        return "Ģ"
    if name == "Gcirc":
        return "Ĝ"
    if name == "Gcy":
        return "Г"
    if name == "Gdot":
        return "Ġ"
    if name == "Gfr":
        return "𝔊"
    if name == "Gg":
        return "⋙"
    if name == "Gopf":
        return "𝔾"
    if name == "GreaterEqual":
        return "≥"
    if name == "GreaterEqualLess":
        return "⋛"
    if name == "GreaterFullEqual":
        return "≧"
    if name == "GreaterGreater":
        return "⪢"
    if name == "GreaterLess":
        return "≷"
    if name == "GreaterSlantEqual":
        return "⩾"
    if name == "GreaterTilde":
        return "≳"
    if name == "Gscr":
        return "𝒢"
    if name == "Gt":
        return "≫"
    if name == "HARDcy":
        return "Ъ"
    if name == "Hacek":
        return "ˇ"
    if name == "Hat":
        return "^"
    if name == "Hcirc":
        return "Ĥ"
    if name == "Hfr":
        return "ℌ"
    if name == "HilbertSpace":
        return "ℋ"
    if name == "Hopf":
        return "ℍ"
    if name == "HorizontalLine":
        return "─"
    if name == "Hscr":
        return "ℋ"
    if name == "Hstrok":
        return "Ħ"
    if name == "HumpDownHump":
        return "≎"
    if name == "HumpEqual":
        return "≏"
    if name == "IEcy":
        return "Е"
    if name == "IJlig":
        return "Ĳ"
    if name == "IOcy":
        return "Ё"
    if name == "Iacute":
        return "Í"
    if name == "Icirc":
        return "Î"
    if name == "Icy":
        return "И"
    if name == "Idot":
        return "İ"
    if name == "Ifr":
        return "ℑ"
    if name == "Igrave":
        return "Ì"
    if name == "Im":
        return "ℑ"
    if name == "Imacr":
        return "Ī"
    if name == "ImaginaryI":
        return "ⅈ"
    if name == "Implies":
        return "⇒"
    if name == "Int":
        return "∬"
    if name == "Integral":
        return "∫"
    if name == "Intersection":
        return "⋂"
    if name == "InvisibleComma":
        return "⁣"
    if name == "InvisibleTimes":
        return "⁢"
    if name == "Iogon":
        return "Į"
    if name == "Iopf":
        return "𝕀"
    if name == "Iota":
        return "Ι"
    if name == "Iscr":
        return "ℐ"
    if name == "Itilde":
        return "Ĩ"
    if name == "Iukcy":
        return "І"
    if name == "Iuml":
        return "Ï"
    if name == "Jcirc":
        return "Ĵ"
    if name == "Jcy":
        return "Й"
    if name == "Jfr":
        return "𝔍"
    if name == "Jopf":
        return "𝕁"
    if name == "Jscr":
        return "𝒥"
    if name == "Jsercy":
        return "Ј"
    if name == "Jukcy":
        return "Є"
    if name == "KHcy":
        return "Х"
    if name == "KJcy":
        return "Ќ"
    if name == "Kappa":
        return "Κ"
    if name == "Kcedil":
        return "Ķ"
    if name == "Kcy":
        return "К"
    if name == "Kfr":
        return "𝔎"
    if name == "Kopf":
        return "𝕂"
    if name == "Kscr":
        return "𝒦"
    if name == "LJcy":
        return "Љ"
    if name == "LT":
        return "<"
    if name == "Lacute":
        return "Ĺ"
    if name == "Lambda":
        return "Λ"
    if name == "Lang":
        return "⟪"
    if name == "Laplacetrf":
        return "ℒ"
    if name == "Larr":
        return "↞"
    if name == "Lcaron":
        return "Ľ"
    if name == "Lcedil":
        return "Ļ"
    if name == "Lcy":
        return "Л"
    if name == "LeftAngleBracket":
        return "⟨"
    if name == "LeftArrow":
        return "←"
    if name == "LeftArrowBar":
        return "⇤"
    if name == "LeftArrowRightArrow":
        return "⇆"
    if name == "LeftCeiling":
        return "⌈"
    if name == "LeftDoubleBracket":
        return "⟦"
    if name == "LeftDownTeeVector":
        return "⥡"
    if name == "LeftDownVector":
        return "⇃"
    if name == "LeftDownVectorBar":
        return "⥙"
    if name == "LeftFloor":
        return "⌊"
    if name == "LeftRightArrow":
        return "↔"
    if name == "LeftRightVector":
        return "⥎"
    if name == "LeftTee":
        return "⊣"
    if name == "LeftTeeArrow":
        return "↤"
    if name == "LeftTeeVector":
        return "⥚"
    if name == "LeftTriangle":
        return "⊲"
    if name == "LeftTriangleBar":
        return "⧏"
    if name == "LeftTriangleEqual":
        return "⊴"
    if name == "LeftUpDownVector":
        return "⥑"
    if name == "LeftUpTeeVector":
        return "⥠"
    if name == "LeftUpVector":
        return "↿"
    if name == "LeftUpVectorBar":
        return "⥘"
    if name == "LeftVector":
        return "↼"
    if name == "LeftVectorBar":
        return "⥒"
    if name == "Leftarrow":
        return "⇐"
    if name == "Leftrightarrow":
        return "⇔"
    if name == "LessEqualGreater":
        return "⋚"
    if name == "LessFullEqual":
        return "≦"
    if name == "LessGreater":
        return "≶"
    if name == "LessLess":
        return "⪡"
    if name == "LessSlantEqual":
        return "⩽"
    if name == "LessTilde":
        return "≲"
    if name == "Lfr":
        return "𝔏"
    if name == "Ll":
        return "⋘"
    if name == "Lleftarrow":
        return "⇚"
    if name == "Lmidot":
        return "Ŀ"
    if name == "LongLeftArrow":
        return "⟵"
    if name == "LongLeftRightArrow":
        return "⟷"
    if name == "LongRightArrow":
        return "⟶"
    if name == "Longleftarrow":
        return "⟸"
    if name == "Longleftrightarrow":
        return "⟺"
    if name == "Longrightarrow":
        return "⟹"
    if name == "Lopf":
        return "𝕃"
    if name == "LowerLeftArrow":
        return "↙"
    if name == "LowerRightArrow":
        return "↘"
    if name == "Lscr":
        return "ℒ"
    if name == "Lsh":
        return "↰"
    if name == "Lstrok":
        return "Ł"
    if name == "Lt":
        return "≪"
    if name == "Map":
        return "⤅"
    if name == "Mcy":
        return "М"
    if name == "MediumSpace":
        return " "
    if name == "Mellintrf":
        return "ℳ"
    if name == "Mfr":
        return "𝔐"
    if name == "MinusPlus":
        return "∓"
    if name == "Mopf":
        return "𝕄"
    if name == "Mscr":
        return "ℳ"
    if name == "Mu":
        return "Μ"
    if name == "NJcy":
        return "Њ"
    if name == "Nacute":
        return "Ń"
    if name == "Ncaron":
        return "Ň"
    if name == "Ncedil":
        return "Ņ"
    if name == "Ncy":
        return "Н"
    if name == "NegativeMediumSpace":
        return "​"
    if name == "NegativeThickSpace":
        return "​"
    if name == "NegativeThinSpace":
        return "​"
    if name == "NegativeVeryThinSpace":
        return "​"
    if name == "NestedGreaterGreater":
        return "≫"
    if name == "NestedLessLess":
        return "≪"
    if name == "NewLine":
        return "\n"
    if name == "Nfr":
        return "𝔑"
    if name == "NoBreak":
        return "⁠"
    if name == "NonBreakingSpace":
        return " "
    if name == "Nopf":
        return "ℕ"
    if name == "Not":
        return "⫬"
    if name == "NotCongruent":
        return "≢"
    if name == "NotCupCap":
        return "≭"
    if name == "NotDoubleVerticalBar":
        return "∦"
    if name == "NotElement":
        return "∉"
    if name == "NotEqual":
        return "≠"
    if name == "NotEqualTilde":
        return "≂̸"
    if name == "NotExists":
        return "∄"
    if name == "NotGreater":
        return "≯"
    if name == "NotGreaterEqual":
        return "≱"
    if name == "NotGreaterFullEqual":
        return "≧̸"
    if name == "NotGreaterGreater":
        return "≫̸"
    if name == "NotGreaterLess":
        return "≹"
    if name == "NotGreaterSlantEqual":
        return "⩾̸"
    if name == "NotGreaterTilde":
        return "≵"
    if name == "NotHumpDownHump":
        return "≎̸"
    if name == "NotHumpEqual":
        return "≏̸"
    if name == "NotLeftTriangle":
        return "⋪"
    if name == "NotLeftTriangleBar":
        return "⧏̸"
    if name == "NotLeftTriangleEqual":
        return "⋬"
    if name == "NotLess":
        return "≮"
    if name == "NotLessEqual":
        return "≰"
    if name == "NotLessGreater":
        return "≸"
    if name == "NotLessLess":
        return "≪̸"
    if name == "NotLessSlantEqual":
        return "⩽̸"
    if name == "NotLessTilde":
        return "≴"
    if name == "NotNestedGreaterGreater":
        return "⪢̸"
    if name == "NotNestedLessLess":
        return "⪡̸"
    if name == "NotPrecedes":
        return "⊀"
    if name == "NotPrecedesEqual":
        return "⪯̸"
    if name == "NotPrecedesSlantEqual":
        return "⋠"
    if name == "NotReverseElement":
        return "∌"
    if name == "NotRightTriangle":
        return "⋫"
    if name == "NotRightTriangleBar":
        return "⧐̸"
    if name == "NotRightTriangleEqual":
        return "⋭"
    if name == "NotSquareSubset":
        return "⊏̸"
    if name == "NotSquareSubsetEqual":
        return "⋢"
    if name == "NotSquareSuperset":
        return "⊐̸"
    if name == "NotSquareSupersetEqual":
        return "⋣"
    if name == "NotSubset":
        return "⊂⃒"
    if name == "NotSubsetEqual":
        return "⊈"
    if name == "NotSucceeds":
        return "⊁"
    if name == "NotSucceedsEqual":
        return "⪰̸"
    if name == "NotSucceedsSlantEqual":
        return "⋡"
    if name == "NotSucceedsTilde":
        return "≿̸"
    if name == "NotSuperset":
        return "⊃⃒"
    if name == "NotSupersetEqual":
        return "⊉"
    if name == "NotTilde":
        return "≁"
    if name == "NotTildeEqual":
        return "≄"
    if name == "NotTildeFullEqual":
        return "≇"
    if name == "NotTildeTilde":
        return "≉"
    if name == "NotVerticalBar":
        return "∤"
    if name == "Nscr":
        return "𝒩"
    if name == "Ntilde":
        return "Ñ"
    if name == "Nu":
        return "Ν"
    if name == "OElig":
        return "Œ"
    if name == "Oacute":
        return "Ó"
    if name == "Ocirc":
        return "Ô"
    if name == "Ocy":
        return "О"
    if name == "Odblac":
        return "Ő"
    if name == "Ofr":
        return "𝔒"
    if name == "Ograve":
        return "Ò"
    if name == "Omacr":
        return "Ō"
    if name == "Omega":
        return "Ω"
    if name == "Omicron":
        return "Ο"
    if name == "Oopf":
        return "𝕆"
    if name == "OpenCurlyDoubleQuote":
        return "“"
    if name == "OpenCurlyQuote":
        return "‘"
    if name == "Or":
        return "⩔"
    if name == "Oscr":
        return "𝒪"
    if name == "Oslash":
        return "Ø"
    if name == "Otilde":
        return "Õ"
    if name == "Otimes":
        return "⨷"
    if name == "Ouml":
        return "Ö"
    if name == "OverBar":
        return "‾"
    if name == "OverBrace":
        return "⏞"
    if name == "OverBracket":
        return "⎴"
    if name == "OverParenthesis":
        return "⏜"
    if name == "PartialD":
        return "∂"
    if name == "Pcy":
        return "П"
    if name == "Pfr":
        return "𝔓"
    if name == "Phi":
        return "Φ"
    if name == "Pi":
        return "Π"
    if name == "PlusMinus":
        return "±"
    if name == "Poincareplane":
        return "ℌ"
    if name == "Popf":
        return "ℙ"
    if name == "Pr":
        return "⪻"
    if name == "Precedes":
        return "≺"
    if name == "PrecedesEqual":
        return "⪯"
    if name == "PrecedesSlantEqual":
        return "≼"
    if name == "PrecedesTilde":
        return "≾"
    if name == "Prime":
        return "″"
    if name == "Product":
        return "∏"
    if name == "Proportion":
        return "∷"
    if name == "Proportional":
        return "∝"
    if name == "Pscr":
        return "𝒫"
    if name == "Psi":
        return "Ψ"
    if name == "QUOT":
        return "\""
    if name == "Qfr":
        return "𝔔"
    if name == "Qopf":
        return "ℚ"
    if name == "Qscr":
        return "𝒬"
    if name == "RBarr":
        return "⤐"
    if name == "REG":
        return "®"
    if name == "Racute":
        return "Ŕ"
    if name == "Rang":
        return "⟫"
    if name == "Rarr":
        return "↠"
    if name == "Rarrtl":
        return "⤖"
    if name == "Rcaron":
        return "Ř"
    if name == "Rcedil":
        return "Ŗ"
    if name == "Rcy":
        return "Р"
    if name == "Re":
        return "ℜ"
    if name == "ReverseElement":
        return "∋"
    if name == "ReverseEquilibrium":
        return "⇋"
    if name == "ReverseUpEquilibrium":
        return "⥯"
    if name == "Rfr":
        return "ℜ"
    if name == "Rho":
        return "Ρ"
    if name == "RightAngleBracket":
        return "⟩"
    if name == "RightArrow":
        return "→"
    if name == "RightArrowBar":
        return "⇥"
    if name == "RightArrowLeftArrow":
        return "⇄"
    if name == "RightCeiling":
        return "⌉"
    if name == "RightDoubleBracket":
        return "⟧"
    if name == "RightDownTeeVector":
        return "⥝"
    if name == "RightDownVector":
        return "⇂"
    if name == "RightDownVectorBar":
        return "⥕"
    if name == "RightFloor":
        return "⌋"
    if name == "RightTee":
        return "⊢"
    if name == "RightTeeArrow":
        return "↦"
    if name == "RightTeeVector":
        return "⥛"
    if name == "RightTriangle":
        return "⊳"
    if name == "RightTriangleBar":
        return "⧐"
    if name == "RightTriangleEqual":
        return "⊵"
    if name == "RightUpDownVector":
        return "⥏"
    if name == "RightUpTeeVector":
        return "⥜"
    if name == "RightUpVector":
        return "↾"
    if name == "RightUpVectorBar":
        return "⥔"
    if name == "RightVector":
        return "⇀"
    if name == "RightVectorBar":
        return "⥓"
    if name == "Rightarrow":
        return "⇒"
    if name == "Ropf":
        return "ℝ"
    if name == "RoundImplies":
        return "⥰"
    if name == "Rrightarrow":
        return "⇛"
    if name == "Rscr":
        return "ℛ"
    if name == "Rsh":
        return "↱"
    if name == "RuleDelayed":
        return "⧴"
    if name == "SHCHcy":
        return "Щ"
    if name == "SHcy":
        return "Ш"
    if name == "SOFTcy":
        return "Ь"
    if name == "Sacute":
        return "Ś"
    if name == "Sc":
        return "⪼"
    if name == "Scaron":
        return "Š"
    if name == "Scedil":
        return "Ş"
    if name == "Scirc":
        return "Ŝ"
    if name == "Scy":
        return "С"
    if name == "Sfr":
        return "𝔖"
    if name == "ShortDownArrow":
        return "↓"
    if name == "ShortLeftArrow":
        return "←"
    if name == "ShortRightArrow":
        return "→"
    if name == "ShortUpArrow":
        return "↑"
    if name == "Sigma":
        return "Σ"
    if name == "SmallCircle":
        return "∘"
    if name == "Sopf":
        return "𝕊"
    if name == "Sqrt":
        return "√"
    if name == "Square":
        return "□"
    if name == "SquareIntersection":
        return "⊓"
    if name == "SquareSubset":
        return "⊏"
    if name == "SquareSubsetEqual":
        return "⊑"
    if name == "SquareSuperset":
        return "⊐"
    if name == "SquareSupersetEqual":
        return "⊒"
    if name == "SquareUnion":
        return "⊔"
    if name == "Sscr":
        return "𝒮"
    if name == "Star":
        return "⋆"
    if name == "Sub":
        return "⋐"
    if name == "Subset":
        return "⋐"
    if name == "SubsetEqual":
        return "⊆"
    if name == "Succeeds":
        return "≻"
    if name == "SucceedsEqual":
        return "⪰"
    if name == "SucceedsSlantEqual":
        return "≽"
    if name == "SucceedsTilde":
        return "≿"
    if name == "SuchThat":
        return "∋"
    if name == "Sum":
        return "∑"
    if name == "Sup":
        return "⋑"
    if name == "Superset":
        return "⊃"
    if name == "SupersetEqual":
        return "⊇"
    if name == "Supset":
        return "⋑"
    if name == "THORN":
        return "Þ"
    if name == "TRADE":
        return "™"
    if name == "TSHcy":
        return "Ћ"
    if name == "TScy":
        return "Ц"
    if name == "Tab":
        return "\t"
    if name == "Tau":
        return "Τ"
    if name == "Tcaron":
        return "Ť"
    if name == "Tcedil":
        return "Ţ"
    if name == "Tcy":
        return "Т"
    if name == "Tfr":
        return "𝔗"
    if name == "Therefore":
        return "∴"
    if name == "Theta":
        return "Θ"
    if name == "ThickSpace":
        return "  "
    if name == "ThinSpace":
        return " "
    if name == "Tilde":
        return "∼"
    if name == "TildeEqual":
        return "≃"
    if name == "TildeFullEqual":
        return "≅"
    if name == "TildeTilde":
        return "≈"
    if name == "Topf":
        return "𝕋"
    if name == "TripleDot":
        return "⃛"
    if name == "Tscr":
        return "𝒯"
    if name == "Tstrok":
        return "Ŧ"
    if name == "Uacute":
        return "Ú"
    if name == "Uarr":
        return "↟"
    if name == "Uarrocir":
        return "⥉"
    if name == "Ubrcy":
        return "Ў"
    if name == "Ubreve":
        return "Ŭ"
    if name == "Ucirc":
        return "Û"
    if name == "Ucy":
        return "У"
    if name == "Udblac":
        return "Ű"
    if name == "Ufr":
        return "𝔘"
    if name == "Ugrave":
        return "Ù"
    if name == "Umacr":
        return "Ū"
    if name == "UnderBar":
        return "_"
    if name == "UnderBrace":
        return "⏟"
    if name == "UnderBracket":
        return "⎵"
    if name == "UnderParenthesis":
        return "⏝"
    if name == "Union":
        return "⋃"
    if name == "UnionPlus":
        return "⊎"
    if name == "Uogon":
        return "Ų"
    if name == "Uopf":
        return "𝕌"
    if name == "UpArrow":
        return "↑"
    if name == "UpArrowBar":
        return "⤒"
    if name == "UpArrowDownArrow":
        return "⇅"
    if name == "UpDownArrow":
        return "↕"
    if name == "UpEquilibrium":
        return "⥮"
    if name == "UpTee":
        return "⊥"
    if name == "UpTeeArrow":
        return "↥"
    if name == "Uparrow":
        return "⇑"
    if name == "Updownarrow":
        return "⇕"
    if name == "UpperLeftArrow":
        return "↖"
    if name == "UpperRightArrow":
        return "↗"
    if name == "Upsi":
        return "ϒ"
    if name == "Upsilon":
        return "Υ"
    if name == "Uring":
        return "Ů"
    if name == "Uscr":
        return "𝒰"
    if name == "Utilde":
        return "Ũ"
    if name == "Uuml":
        return "Ü"
    if name == "VDash":
        return "⊫"
    if name == "Vbar":
        return "⫫"
    if name == "Vcy":
        return "В"
    if name == "Vdash":
        return "⊩"
    if name == "Vdashl":
        return "⫦"
    if name == "Vee":
        return "⋁"
    if name == "Verbar":
        return "‖"
    if name == "Vert":
        return "‖"
    if name == "VerticalBar":
        return "∣"
    if name == "VerticalLine":
        return "|"
    if name == "VerticalSeparator":
        return "❘"
    if name == "VerticalTilde":
        return "≀"
    if name == "VeryThinSpace":
        return " "
    if name == "Vfr":
        return "𝔙"
    if name == "Vopf":
        return "𝕍"
    if name == "Vscr":
        return "𝒱"
    if name == "Vvdash":
        return "⊪"
    if name == "Wcirc":
        return "Ŵ"
    if name == "Wedge":
        return "⋀"
    if name == "Wfr":
        return "𝔚"
    if name == "Wopf":
        return "𝕎"
    if name == "Wscr":
        return "𝒲"
    if name == "Xfr":
        return "𝔛"
    if name == "Xi":
        return "Ξ"
    if name == "Xopf":
        return "𝕏"
    if name == "Xscr":
        return "𝒳"
    if name == "YAcy":
        return "Я"
    if name == "YIcy":
        return "Ї"
    if name == "YUcy":
        return "Ю"
    if name == "Yacute":
        return "Ý"
    if name == "Ycirc":
        return "Ŷ"
    if name == "Ycy":
        return "Ы"
    if name == "Yfr":
        return "𝔜"
    if name == "Yopf":
        return "𝕐"
    if name == "Yscr":
        return "𝒴"
    if name == "Yuml":
        return "Ÿ"
    if name == "ZHcy":
        return "Ж"
    if name == "Zacute":
        return "Ź"
    if name == "Zcaron":
        return "Ž"
    if name == "Zcy":
        return "З"
    if name == "Zdot":
        return "Ż"
    if name == "ZeroWidthSpace":
        return "​"
    if name == "Zeta":
        return "Ζ"
    if name == "Zfr":
        return "ℨ"
    if name == "Zopf":
        return "ℤ"
    if name == "Zscr":
        return "𝒵"
    if name == "aacute":
        return "á"
    if name == "abreve":
        return "ă"
    if name == "ac":
        return "∾"
    if name == "acE":
        return "∾̳"
    if name == "acd":
        return "∿"
    if name == "acirc":
        return "â"
    if name == "acute":
        return "´"
    if name == "acy":
        return "а"
    if name == "aelig":
        return "æ"
    if name == "af":
        return "⁡"
    if name == "afr":
        return "𝔞"
    if name == "agrave":
        return "à"
    if name == "alefsym":
        return "ℵ"
    if name == "aleph":
        return "ℵ"
    if name == "alpha":
        return "α"
    if name == "amacr":
        return "ā"
    if name == "amalg":
        return "⨿"
    if name == "amp":
        return "&"
    if name == "and":
        return "∧"
    if name == "andand":
        return "⩕"
    if name == "andd":
        return "⩜"
    if name == "andslope":
        return "⩘"
    if name == "andv":
        return "⩚"
    if name == "ang":
        return "∠"
    if name == "ange":
        return "⦤"
    if name == "angle":
        return "∠"
    if name == "angmsd":
        return "∡"
    if name == "angmsdaa":
        return "⦨"
    if name == "angmsdab":
        return "⦩"
    if name == "angmsdac":
        return "⦪"
    if name == "angmsdad":
        return "⦫"
    if name == "angmsdae":
        return "⦬"
    if name == "angmsdaf":
        return "⦭"
    if name == "angmsdag":
        return "⦮"
    if name == "angmsdah":
        return "⦯"
    if name == "angrt":
        return "∟"
    if name == "angrtvb":
        return "⊾"
    if name == "angrtvbd":
        return "⦝"
    if name == "angsph":
        return "∢"
    if name == "angst":
        return "Å"
    if name == "angzarr":
        return "⍼"
    if name == "aogon":
        return "ą"
    if name == "aopf":
        return "𝕒"
    if name == "ap":
        return "≈"
    if name == "apE":
        return "⩰"
    if name == "apacir":
        return "⩯"
    if name == "ape":
        return "≊"
    if name == "apid":
        return "≋"
    if name == "apos":
        return "'"
    if name == "approx":
        return "≈"
    if name == "approxeq":
        return "≊"
    if name == "aring":
        return "å"
    if name == "ascr":
        return "𝒶"
    if name == "ast":
        return "*"
    if name == "asymp":
        return "≈"
    if name == "asympeq":
        return "≍"
    if name == "atilde":
        return "ã"
    if name == "auml":
        return "ä"
    if name == "awconint":
        return "∳"
    if name == "awint":
        return "⨑"
    if name == "bNot":
        return "⫭"
    if name == "backcong":
        return "≌"
    if name == "backepsilon":
        return "϶"
    if name == "backprime":
        return "‵"
    if name == "backsim":
        return "∽"
    if name == "backsimeq":
        return "⋍"
    if name == "barvee":
        return "⊽"
    if name == "barwed":
        return "⌅"
    if name == "barwedge":
        return "⌅"
    if name == "bbrk":
        return "⎵"
    if name == "bbrktbrk":
        return "⎶"
    if name == "bcong":
        return "≌"
    if name == "bcy":
        return "б"
    if name == "bdquo":
        return "„"
    if name == "becaus":
        return "∵"
    if name == "because":
        return "∵"
    if name == "bemptyv":
        return "⦰"
    if name == "bepsi":
        return "϶"
    if name == "bernou":
        return "ℬ"
    if name == "beta":
        return "β"
    if name == "beth":
        return "ℶ"
    if name == "between":
        return "≬"
    if name == "bfr":
        return "𝔟"
    if name == "bigcap":
        return "⋂"
    if name == "bigcirc":
        return "◯"
    if name == "bigcup":
        return "⋃"
    if name == "bigodot":
        return "⨀"
    if name == "bigoplus":
        return "⨁"
    if name == "bigotimes":
        return "⨂"
    if name == "bigsqcup":
        return "⨆"
    if name == "bigstar":
        return "★"
    if name == "bigtriangledown":
        return "▽"
    if name == "bigtriangleup":
        return "△"
    if name == "biguplus":
        return "⨄"
    if name == "bigvee":
        return "⋁"
    if name == "bigwedge":
        return "⋀"
    if name == "bkarow":
        return "⤍"
    if name == "blacklozenge":
        return "⧫"
    if name == "blacksquare":
        return "▪"
    if name == "blacktriangle":
        return "▴"
    if name == "blacktriangledown":
        return "▾"
    if name == "blacktriangleleft":
        return "◂"
    if name == "blacktriangleright":
        return "▸"
    if name == "blank":
        return "␣"
    if name == "blk12":
        return "▒"
    if name == "blk14":
        return "░"
    if name == "blk34":
        return "▓"
    if name == "block":
        return "█"
    if name == "bne":
        return "=⃥"
    if name == "bnequiv":
        return "≡⃥"
    if name == "bnot":
        return "⌐"
    if name == "bopf":
        return "𝕓"
    if name == "bot":
        return "⊥"
    if name == "bottom":
        return "⊥"
    if name == "bowtie":
        return "⋈"
    if name == "boxDL":
        return "╗"
    if name == "boxDR":
        return "╔"
    if name == "boxDl":
        return "╖"
    if name == "boxDr":
        return "╓"
    if name == "boxH":
        return "═"
    if name == "boxHD":
        return "╦"
    if name == "boxHU":
        return "╩"
    if name == "boxHd":
        return "╤"
    if name == "boxHu":
        return "╧"
    if name == "boxUL":
        return "╝"
    if name == "boxUR":
        return "╚"
    if name == "boxUl":
        return "╜"
    if name == "boxUr":
        return "╙"
    if name == "boxV":
        return "║"
    if name == "boxVH":
        return "╬"
    if name == "boxVL":
        return "╣"
    if name == "boxVR":
        return "╠"
    if name == "boxVh":
        return "╫"
    if name == "boxVl":
        return "╢"
    if name == "boxVr":
        return "╟"
    if name == "boxbox":
        return "⧉"
    if name == "boxdL":
        return "╕"
    if name == "boxdR":
        return "╒"
    if name == "boxdl":
        return "┐"
    if name == "boxdr":
        return "┌"
    if name == "boxh":
        return "─"
    if name == "boxhD":
        return "╥"
    if name == "boxhU":
        return "╨"
    if name == "boxhd":
        return "┬"
    if name == "boxhu":
        return "┴"
    if name == "boxminus":
        return "⊟"
    if name == "boxplus":
        return "⊞"
    if name == "boxtimes":
        return "⊠"
    if name == "boxuL":
        return "╛"
    if name == "boxuR":
        return "╘"
    if name == "boxul":
        return "┘"
    if name == "boxur":
        return "└"
    if name == "boxv":
        return "│"
    if name == "boxvH":
        return "╪"
    if name == "boxvL":
        return "╡"
    if name == "boxvR":
        return "╞"
    if name == "boxvh":
        return "┼"
    if name == "boxvl":
        return "┤"
    if name == "boxvr":
        return "├"
    if name == "bprime":
        return "‵"
    if name == "breve":
        return "˘"
    if name == "brvbar":
        return "¦"
    if name == "bscr":
        return "𝒷"
    if name == "bsemi":
        return "⁏"
    if name == "bsim":
        return "∽"
    if name == "bsime":
        return "⋍"
    if name == "bsol":
        return "\\"
    if name == "bsolb":
        return "⧅"
    if name == "bsolhsub":
        return "⟈"
    if name == "bull":
        return "•"
    if name == "bullet":
        return "•"
    if name == "bump":
        return "≎"
    if name == "bumpE":
        return "⪮"
    if name == "bumpe":
        return "≏"
    if name == "bumpeq":
        return "≏"
    if name == "cacute":
        return "ć"
    if name == "cap":
        return "∩"
    if name == "capand":
        return "⩄"
    if name == "capbrcup":
        return "⩉"
    if name == "capcap":
        return "⩋"
    if name == "capcup":
        return "⩇"
    if name == "capdot":
        return "⩀"
    if name == "caps":
        return "∩︀"
    if name == "caret":
        return "⁁"
    if name == "caron":
        return "ˇ"
    if name == "ccaps":
        return "⩍"
    if name == "ccaron":
        return "č"
    if name == "ccedil":
        return "ç"
    if name == "ccirc":
        return "ĉ"
    if name == "ccups":
        return "⩌"
    if name == "ccupssm":
        return "⩐"
    if name == "cdot":
        return "ċ"
    if name == "cedil":
        return "¸"
    if name == "cemptyv":
        return "⦲"
    if name == "cent":
        return "¢"
    if name == "centerdot":
        return "·"
    if name == "cfr":
        return "𝔠"
    if name == "chcy":
        return "ч"
    if name == "check":
        return "✓"
    if name == "checkmark":
        return "✓"
    if name == "chi":
        return "χ"
    if name == "cir":
        return "○"
    if name == "cirE":
        return "⧃"
    if name == "circ":
        return "ˆ"
    if name == "circeq":
        return "≗"
    if name == "circlearrowleft":
        return "↺"
    if name == "circlearrowright":
        return "↻"
    if name == "circledR":
        return "®"
    if name == "circledS":
        return "Ⓢ"
    if name == "circledast":
        return "⊛"
    if name == "circledcirc":
        return "⊚"
    if name == "circleddash":
        return "⊝"
    if name == "cire":
        return "≗"
    if name == "cirfnint":
        return "⨐"
    if name == "cirmid":
        return "⫯"
    if name == "cirscir":
        return "⧂"
    if name == "clubs":
        return "♣"
    if name == "clubsuit":
        return "♣"
    if name == "colon":
        return ":"
    if name == "colone":
        return "≔"
    if name == "coloneq":
        return "≔"
    if name == "comma":
        return ","
    if name == "commat":
        return "@"
    if name == "comp":
        return "∁"
    if name == "compfn":
        return "∘"
    if name == "complement":
        return "∁"
    if name == "complexes":
        return "ℂ"
    if name == "cong":
        return "≅"
    if name == "congdot":
        return "⩭"
    if name == "conint":
        return "∮"
    if name == "copf":
        return "𝕔"
    if name == "coprod":
        return "∐"
    if name == "copy":
        return "©"
    if name == "copysr":
        return "℗"
    if name == "crarr":
        return "↵"
    if name == "cross":
        return "✗"
    if name == "cscr":
        return "𝒸"
    if name == "csub":
        return "⫏"
    if name == "csube":
        return "⫑"
    if name == "csup":
        return "⫐"
    if name == "csupe":
        return "⫒"
    if name == "ctdot":
        return "⋯"
    if name == "cudarrl":
        return "⤸"
    if name == "cudarrr":
        return "⤵"
    if name == "cuepr":
        return "⋞"
    if name == "cuesc":
        return "⋟"
    if name == "cularr":
        return "↶"
    if name == "cularrp":
        return "⤽"
    if name == "cup":
        return "∪"
    if name == "cupbrcap":
        return "⩈"
    if name == "cupcap":
        return "⩆"
    if name == "cupcup":
        return "⩊"
    if name == "cupdot":
        return "⊍"
    if name == "cupor":
        return "⩅"
    if name == "cups":
        return "∪︀"
    if name == "curarr":
        return "↷"
    if name == "curarrm":
        return "⤼"
    if name == "curlyeqprec":
        return "⋞"
    if name == "curlyeqsucc":
        return "⋟"
    if name == "curlyvee":
        return "⋎"
    if name == "curlywedge":
        return "⋏"
    if name == "curren":
        return "¤"
    if name == "curvearrowleft":
        return "↶"
    if name == "curvearrowright":
        return "↷"
    if name == "cuvee":
        return "⋎"
    if name == "cuwed":
        return "⋏"
    if name == "cwconint":
        return "∲"
    if name == "cwint":
        return "∱"
    if name == "cylcty":
        return "⌭"
    if name == "dArr":
        return "⇓"
    if name == "dHar":
        return "⥥"
    if name == "dagger":
        return "†"
    if name == "daleth":
        return "ℸ"
    if name == "darr":
        return "↓"
    if name == "dash":
        return "‐"
    if name == "dashv":
        return "⊣"
    if name == "dbkarow":
        return "⤏"
    if name == "dblac":
        return "˝"
    if name == "dcaron":
        return "ď"
    if name == "dcy":
        return "д"
    if name == "dd":
        return "ⅆ"
    if name == "ddagger":
        return "‡"
    if name == "ddarr":
        return "⇊"
    if name == "ddotseq":
        return "⩷"
    if name == "deg":
        return "°"
    if name == "delta":
        return "δ"
    if name == "demptyv":
        return "⦱"
    if name == "dfisht":
        return "⥿"
    if name == "dfr":
        return "𝔡"
    if name == "dharl":
        return "⇃"
    if name == "dharr":
        return "⇂"
    if name == "diam":
        return "⋄"
    if name == "diamond":
        return "⋄"
    if name == "diamondsuit":
        return "♦"
    if name == "diams":
        return "♦"
    if name == "die":
        return "¨"
    if name == "digamma":
        return "ϝ"
    if name == "disin":
        return "⋲"
    if name == "div":
        return "÷"
    if name == "divide":
        return "÷"
    if name == "divideontimes":
        return "⋇"
    if name == "divonx":
        return "⋇"
    if name == "djcy":
        return "ђ"
    if name == "dlcorn":
        return "⌞"
    if name == "dlcrop":
        return "⌍"
    if name == "dollar":
        return "$"
    if name == "dopf":
        return "𝕕"
    if name == "dot":
        return "˙"
    if name == "doteq":
        return "≐"
    if name == "doteqdot":
        return "≑"
    if name == "dotminus":
        return "∸"
    if name == "dotplus":
        return "∔"
    if name == "dotsquare":
        return "⊡"
    if name == "doublebarwedge":
        return "⌆"
    if name == "downarrow":
        return "↓"
    if name == "downdownarrows":
        return "⇊"
    if name == "downharpoonleft":
        return "⇃"
    if name == "downharpoonright":
        return "⇂"
    if name == "drbkarow":
        return "⤐"
    if name == "drcorn":
        return "⌟"
    if name == "drcrop":
        return "⌌"
    if name == "dscr":
        return "𝒹"
    if name == "dscy":
        return "ѕ"
    if name == "dsol":
        return "⧶"
    if name == "dstrok":
        return "đ"
    if name == "dtdot":
        return "⋱"
    if name == "dtri":
        return "▿"
    if name == "dtrif":
        return "▾"
    if name == "duarr":
        return "⇵"
    if name == "duhar":
        return "⥯"
    if name == "dwangle":
        return "⦦"
    if name == "dzcy":
        return "џ"
    if name == "dzigrarr":
        return "⟿"
    if name == "eDDot":
        return "⩷"
    if name == "eDot":
        return "≑"
    if name == "eacute":
        return "é"
    if name == "easter":
        return "⩮"
    if name == "ecaron":
        return "ě"
    if name == "ecir":
        return "≖"
    if name == "ecirc":
        return "ê"
    if name == "ecolon":
        return "≕"
    if name == "ecy":
        return "э"
    if name == "edot":
        return "ė"
    if name == "ee":
        return "ⅇ"
    if name == "efDot":
        return "≒"
    if name == "efr":
        return "𝔢"
    if name == "eg":
        return "⪚"
    if name == "egrave":
        return "è"
    if name == "egs":
        return "⪖"
    if name == "egsdot":
        return "⪘"
    if name == "el":
        return "⪙"
    if name == "elinters":
        return "⏧"
    if name == "ell":
        return "ℓ"
    if name == "els":
        return "⪕"
    if name == "elsdot":
        return "⪗"
    if name == "emacr":
        return "ē"
    if name == "empty":
        return "∅"
    if name == "emptyset":
        return "∅"
    if name == "emptyv":
        return "∅"
    if name == "emsp":
        return " "
    if name == "emsp13":
        return " "
    if name == "emsp14":
        return " "
    if name == "eng":
        return "ŋ"
    if name == "ensp":
        return " "
    if name == "eogon":
        return "ę"
    if name == "eopf":
        return "𝕖"
    if name == "epar":
        return "⋕"
    if name == "eparsl":
        return "⧣"
    if name == "eplus":
        return "⩱"
    if name == "epsi":
        return "ε"
    if name == "epsilon":
        return "ε"
    if name == "epsiv":
        return "ϵ"
    if name == "eqcirc":
        return "≖"
    if name == "eqcolon":
        return "≕"
    if name == "eqsim":
        return "≂"
    if name == "eqslantgtr":
        return "⪖"
    if name == "eqslantless":
        return "⪕"
    if name == "equals":
        return "="
    if name == "equest":
        return "≟"
    if name == "equiv":
        return "≡"
    if name == "equivDD":
        return "⩸"
    if name == "eqvparsl":
        return "⧥"
    if name == "erDot":
        return "≓"
    if name == "erarr":
        return "⥱"
    if name == "escr":
        return "ℯ"
    if name == "esdot":
        return "≐"
    if name == "esim":
        return "≂"
    if name == "eta":
        return "η"
    if name == "eth":
        return "ð"
    if name == "euml":
        return "ë"
    if name == "euro":
        return "€"
    if name == "excl":
        return "!"
    if name == "exist":
        return "∃"
    if name == "expectation":
        return "ℰ"
    if name == "exponentiale":
        return "ⅇ"
    if name == "fallingdotseq":
        return "≒"
    if name == "fcy":
        return "ф"
    if name == "female":
        return "♀"
    if name == "ffilig":
        return "ﬃ"
    if name == "fflig":
        return "ﬀ"
    if name == "ffllig":
        return "ﬄ"
    if name == "ffr":
        return "𝔣"
    if name == "filig":
        return "ﬁ"
    if name == "fjlig":
        return "fj"
    if name == "flat":
        return "♭"
    if name == "fllig":
        return "ﬂ"
    if name == "fltns":
        return "▱"
    if name == "fnof":
        return "ƒ"
    if name == "fopf":
        return "𝕗"
    if name == "forall":
        return "∀"
    if name == "fork":
        return "⋔"
    if name == "forkv":
        return "⫙"
    if name == "fpartint":
        return "⨍"
    if name == "frac12":
        return "½"
    if name == "frac13":
        return "⅓"
    if name == "frac14":
        return "¼"
    if name == "frac15":
        return "⅕"
    if name == "frac16":
        return "⅙"
    if name == "frac18":
        return "⅛"
    if name == "frac23":
        return "⅔"
    if name == "frac25":
        return "⅖"
    if name == "frac34":
        return "¾"
    if name == "frac35":
        return "⅗"
    if name == "frac38":
        return "⅜"
    if name == "frac45":
        return "⅘"
    if name == "frac56":
        return "⅚"
    if name == "frac58":
        return "⅝"
    if name == "frac78":
        return "⅞"
    if name == "frasl":
        return "⁄"
    if name == "frown":
        return "⌢"
    if name == "fscr":
        return "𝒻"
    if name == "gE":
        return "≧"
    if name == "gEl":
        return "⪌"
    if name == "gacute":
        return "ǵ"
    if name == "gamma":
        return "γ"
    if name == "gammad":
        return "ϝ"
    if name == "gap":
        return "⪆"
    if name == "gbreve":
        return "ğ"
    if name == "gcirc":
        return "ĝ"
    if name == "gcy":
        return "г"
    if name == "gdot":
        return "ġ"
    if name == "ge":
        return "≥"
    if name == "gel":
        return "⋛"
    if name == "geq":
        return "≥"
    if name == "geqq":
        return "≧"
    if name == "geqslant":
        return "⩾"
    if name == "ges":
        return "⩾"
    if name == "gescc":
        return "⪩"
    if name == "gesdot":
        return "⪀"
    if name == "gesdoto":
        return "⪂"
    if name == "gesdotol":
        return "⪄"
    if name == "gesl":
        return "⋛︀"
    if name == "gesles":
        return "⪔"
    if name == "gfr":
        return "𝔤"
    if name == "gg":
        return "≫"
    if name == "ggg":
        return "⋙"
    if name == "gimel":
        return "ℷ"
    if name == "gjcy":
        return "ѓ"
    if name == "gl":
        return "≷"
    if name == "glE":
        return "⪒"
    if name == "gla":
        return "⪥"
    if name == "glj":
        return "⪤"
    if name == "gnE":
        return "≩"
    if name == "gnap":
        return "⪊"
    if name == "gnapprox":
        return "⪊"
    if name == "gne":
        return "⪈"
    if name == "gneq":
        return "⪈"
    if name == "gneqq":
        return "≩"
    if name == "gnsim":
        return "⋧"
    if name == "gopf":
        return "𝕘"
    if name == "grave":
        return "`"
    if name == "gscr":
        return "ℊ"
    if name == "gsim":
        return "≳"
    if name == "gsime":
        return "⪎"
    if name == "gsiml":
        return "⪐"
    if name == "gt":
        return ">"
    if name == "gtcc":
        return "⪧"
    if name == "gtcir":
        return "⩺"
    if name == "gtdot":
        return "⋗"
    if name == "gtlPar":
        return "⦕"
    if name == "gtquest":
        return "⩼"
    if name == "gtrapprox":
        return "⪆"
    if name == "gtrarr":
        return "⥸"
    if name == "gtrdot":
        return "⋗"
    if name == "gtreqless":
        return "⋛"
    if name == "gtreqqless":
        return "⪌"
    if name == "gtrless":
        return "≷"
    if name == "gtrsim":
        return "≳"
    if name == "gvertneqq":
        return "≩︀"
    if name == "gvnE":
        return "≩︀"
    if name == "hArr":
        return "⇔"
    if name == "hairsp":
        return " "
    if name == "half":
        return "½"
    if name == "hamilt":
        return "ℋ"
    if name == "hardcy":
        return "ъ"
    if name == "harr":
        return "↔"
    if name == "harrcir":
        return "⥈"
    if name == "harrw":
        return "↭"
    if name == "hbar":
        return "ℏ"
    if name == "hcirc":
        return "ĥ"
    if name == "hearts":
        return "♥"
    if name == "heartsuit":
        return "♥"
    if name == "hellip":
        return "…"
    if name == "hercon":
        return "⊹"
    if name == "hfr":
        return "𝔥"
    if name == "hksearow":
        return "⤥"
    if name == "hkswarow":
        return "⤦"
    if name == "hoarr":
        return "⇿"
    if name == "homtht":
        return "∻"
    if name == "hookleftarrow":
        return "↩"
    if name == "hookrightarrow":
        return "↪"
    if name == "hopf":
        return "𝕙"
    if name == "horbar":
        return "―"
    if name == "hscr":
        return "𝒽"
    if name == "hslash":
        return "ℏ"
    if name == "hstrok":
        return "ħ"
    if name == "hybull":
        return "⁃"
    if name == "hyphen":
        return "‐"
    if name == "iacute":
        return "í"
    if name == "ic":
        return "⁣"
    if name == "icirc":
        return "î"
    if name == "icy":
        return "и"
    if name == "iecy":
        return "е"
    if name == "iexcl":
        return "¡"
    if name == "iff":
        return "⇔"
    if name == "ifr":
        return "𝔦"
    if name == "igrave":
        return "ì"
    if name == "ii":
        return "ⅈ"
    if name == "iiiint":
        return "⨌"
    if name == "iiint":
        return "∭"
    if name == "iinfin":
        return "⧜"
    if name == "iiota":
        return "℩"
    if name == "ijlig":
        return "ĳ"
    if name == "imacr":
        return "ī"
    if name == "image":
        return "ℑ"
    if name == "imagline":
        return "ℐ"
    if name == "imagpart":
        return "ℑ"
    if name == "imath":
        return "ı"
    if name == "imof":
        return "⊷"
    if name == "imped":
        return "Ƶ"
    if name == "in":
        return "∈"
    if name == "incare":
        return "℅"
    if name == "infin":
        return "∞"
    if name == "infintie":
        return "⧝"
    if name == "inodot":
        return "ı"
    if name == "int":
        return "∫"
    if name == "intcal":
        return "⊺"
    if name == "integers":
        return "ℤ"
    if name == "intercal":
        return "⊺"
    if name == "intlarhk":
        return "⨗"
    if name == "intprod":
        return "⨼"
    if name == "iocy":
        return "ё"
    if name == "iogon":
        return "į"
    if name == "iopf":
        return "𝕚"
    if name == "iota":
        return "ι"
    if name == "iprod":
        return "⨼"
    if name == "iquest":
        return "¿"
    if name == "iscr":
        return "𝒾"
    if name == "isin":
        return "∈"
    if name == "isinE":
        return "⋹"
    if name == "isindot":
        return "⋵"
    if name == "isins":
        return "⋴"
    if name == "isinsv":
        return "⋳"
    if name == "isinv":
        return "∈"
    if name == "it":
        return "⁢"
    if name == "itilde":
        return "ĩ"
    if name == "iukcy":
        return "і"
    if name == "iuml":
        return "ï"
    if name == "jcirc":
        return "ĵ"
    if name == "jcy":
        return "й"
    if name == "jfr":
        return "𝔧"
    if name == "jmath":
        return "ȷ"
    if name == "jopf":
        return "𝕛"
    if name == "jscr":
        return "𝒿"
    if name == "jsercy":
        return "ј"
    if name == "jukcy":
        return "є"
    if name == "kappa":
        return "κ"
    if name == "kappav":
        return "ϰ"
    if name == "kcedil":
        return "ķ"
    if name == "kcy":
        return "к"
    if name == "kfr":
        return "𝔨"
    if name == "kgreen":
        return "ĸ"
    if name == "khcy":
        return "х"
    if name == "kjcy":
        return "ќ"
    if name == "kopf":
        return "𝕜"
    if name == "kscr":
        return "𝓀"
    if name == "lAarr":
        return "⇚"
    if name == "lArr":
        return "⇐"
    if name == "lAtail":
        return "⤛"
    if name == "lBarr":
        return "⤎"
    if name == "lE":
        return "≦"
    if name == "lEg":
        return "⪋"
    if name == "lHar":
        return "⥢"
    if name == "lacute":
        return "ĺ"
    if name == "laemptyv":
        return "⦴"
    if name == "lagran":
        return "ℒ"
    if name == "lambda":
        return "λ"
    if name == "lang":
        return "⟨"
    if name == "langd":
        return "⦑"
    if name == "langle":
        return "⟨"
    if name == "lap":
        return "⪅"
    if name == "laquo":
        return "«"
    if name == "larr":
        return "←"
    if name == "larrb":
        return "⇤"
    if name == "larrbfs":
        return "⤟"
    if name == "larrfs":
        return "⤝"
    if name == "larrhk":
        return "↩"
    if name == "larrlp":
        return "↫"
    if name == "larrpl":
        return "⤹"
    if name == "larrsim":
        return "⥳"
    if name == "larrtl":
        return "↢"
    if name == "lat":
        return "⪫"
    if name == "latail":
        return "⤙"
    if name == "late":
        return "⪭"
    if name == "lates":
        return "⪭︀"
    if name == "lbarr":
        return "⤌"
    if name == "lbbrk":
        return "❲"
    if name == "lbrace":
        return "{"
    if name == "lbrack":
        return "["
    if name == "lbrke":
        return "⦋"
    if name == "lbrksld":
        return "⦏"
    if name == "lbrkslu":
        return "⦍"
    if name == "lcaron":
        return "ľ"
    if name == "lcedil":
        return "ļ"
    if name == "lceil":
        return "⌈"
    if name == "lcub":
        return "{"
    if name == "lcy":
        return "л"
    if name == "ldca":
        return "⤶"
    if name == "ldquo":
        return "“"
    if name == "ldquor":
        return "„"
    if name == "ldrdhar":
        return "⥧"
    if name == "ldrushar":
        return "⥋"
    if name == "ldsh":
        return "↲"
    if name == "le":
        return "≤"
    if name == "leftarrow":
        return "←"
    if name == "leftarrowtail":
        return "↢"
    if name == "leftharpoondown":
        return "↽"
    if name == "leftharpoonup":
        return "↼"
    if name == "leftleftarrows":
        return "⇇"
    if name == "leftrightarrow":
        return "↔"
    if name == "leftrightarrows":
        return "⇆"
    if name == "leftrightharpoons":
        return "⇋"
    if name == "leftrightsquigarrow":
        return "↭"
    if name == "leftthreetimes":
        return "⋋"
    if name == "leg":
        return "⋚"
    if name == "leq":
        return "≤"
    if name == "leqq":
        return "≦"
    if name == "leqslant":
        return "⩽"
    if name == "les":
        return "⩽"
    if name == "lescc":
        return "⪨"
    if name == "lesdot":
        return "⩿"
    if name == "lesdoto":
        return "⪁"
    if name == "lesdotor":
        return "⪃"
    if name == "lesg":
        return "⋚︀"
    if name == "lesges":
        return "⪓"
    if name == "lessapprox":
        return "⪅"
    if name == "lessdot":
        return "⋖"
    if name == "lesseqgtr":
        return "⋚"
    if name == "lesseqqgtr":
        return "⪋"
    if name == "lessgtr":
        return "≶"
    if name == "lesssim":
        return "≲"
    if name == "lfisht":
        return "⥼"
    if name == "lfloor":
        return "⌊"
    if name == "lfr":
        return "𝔩"
    if name == "lg":
        return "≶"
    if name == "lgE":
        return "⪑"
    if name == "lhard":
        return "↽"
    if name == "lharu":
        return "↼"
    if name == "lharul":
        return "⥪"
    if name == "lhblk":
        return "▄"
    if name == "ljcy":
        return "љ"
    if name == "ll":
        return "≪"
    if name == "llarr":
        return "⇇"
    if name == "llcorner":
        return "⌞"
    if name == "llhard":
        return "⥫"
    if name == "lltri":
        return "◺"
    if name == "lmidot":
        return "ŀ"
    if name == "lmoust":
        return "⎰"
    if name == "lmoustache":
        return "⎰"
    if name == "lnE":
        return "≨"
    if name == "lnap":
        return "⪉"
    if name == "lnapprox":
        return "⪉"
    if name == "lne":
        return "⪇"
    if name == "lneq":
        return "⪇"
    if name == "lneqq":
        return "≨"
    if name == "lnsim":
        return "⋦"
    if name == "loang":
        return "⟬"
    if name == "loarr":
        return "⇽"
    if name == "lobrk":
        return "⟦"
    if name == "longleftarrow":
        return "⟵"
    if name == "longleftrightarrow":
        return "⟷"
    if name == "longmapsto":
        return "⟼"
    if name == "longrightarrow":
        return "⟶"
    if name == "looparrowleft":
        return "↫"
    if name == "looparrowright":
        return "↬"
    if name == "lopar":
        return "⦅"
    if name == "lopf":
        return "𝕝"
    if name == "loplus":
        return "⨭"
    if name == "lotimes":
        return "⨴"
    if name == "lowast":
        return "∗"
    if name == "lowbar":
        return "_"
    if name == "loz":
        return "◊"
    if name == "lozenge":
        return "◊"
    if name == "lozf":
        return "⧫"
    if name == "lpar":
        return "("
    if name == "lparlt":
        return "⦓"
    if name == "lrarr":
        return "⇆"
    if name == "lrcorner":
        return "⌟"
    if name == "lrhar":
        return "⇋"
    if name == "lrhard":
        return "⥭"
    if name == "lrm":
        return "‎"
    if name == "lrtri":
        return "⊿"
    if name == "lsaquo":
        return "‹"
    if name == "lscr":
        return "𝓁"
    if name == "lsh":
        return "↰"
    if name == "lsim":
        return "≲"
    if name == "lsime":
        return "⪍"
    if name == "lsimg":
        return "⪏"
    if name == "lsqb":
        return "["
    if name == "lsquo":
        return "‘"
    if name == "lsquor":
        return "‚"
    if name == "lstrok":
        return "ł"
    if name == "lt":
        return "<"
    if name == "ltcc":
        return "⪦"
    if name == "ltcir":
        return "⩹"
    if name == "ltdot":
        return "⋖"
    if name == "lthree":
        return "⋋"
    if name == "ltimes":
        return "⋉"
    if name == "ltlarr":
        return "⥶"
    if name == "ltquest":
        return "⩻"
    if name == "ltrPar":
        return "⦖"
    if name == "ltri":
        return "◃"
    if name == "ltrie":
        return "⊴"
    if name == "ltrif":
        return "◂"
    if name == "lurdshar":
        return "⥊"
    if name == "luruhar":
        return "⥦"
    if name == "lvertneqq":
        return "≨︀"
    if name == "lvnE":
        return "≨︀"
    if name == "mDDot":
        return "∺"
    if name == "macr":
        return "¯"
    if name == "male":
        return "♂"
    if name == "malt":
        return "✠"
    if name == "maltese":
        return "✠"
    if name == "map":
        return "↦"
    if name == "mapsto":
        return "↦"
    if name == "mapstodown":
        return "↧"
    if name == "mapstoleft":
        return "↤"
    if name == "mapstoup":
        return "↥"
    if name == "marker":
        return "▮"
    if name == "mcomma":
        return "⨩"
    if name == "mcy":
        return "м"
    if name == "mdash":
        return "—"
    if name == "measuredangle":
        return "∡"
    if name == "mfr":
        return "𝔪"
    if name == "mho":
        return "℧"
    if name == "micro":
        return "µ"
    if name == "mid":
        return "∣"
    if name == "midast":
        return "*"
    if name == "midcir":
        return "⫰"
    if name == "middot":
        return "·"
    if name == "minus":
        return "−"
    if name == "minusb":
        return "⊟"
    if name == "minusd":
        return "∸"
    if name == "minusdu":
        return "⨪"
    if name == "mlcp":
        return "⫛"
    if name == "mldr":
        return "…"
    if name == "mnplus":
        return "∓"
    if name == "models":
        return "⊧"
    if name == "mopf":
        return "𝕞"
    if name == "mp":
        return "∓"
    if name == "mscr":
        return "𝓂"
    if name == "mstpos":
        return "∾"
    if name == "mu":
        return "μ"
    if name == "multimap":
        return "⊸"
    if name == "mumap":
        return "⊸"
    if name == "nGg":
        return "⋙̸"
    if name == "nGt":
        return "≫⃒"
    if name == "nGtv":
        return "≫̸"
    if name == "nLeftarrow":
        return "⇍"
    if name == "nLeftrightarrow":
        return "⇎"
    if name == "nLl":
        return "⋘̸"
    if name == "nLt":
        return "≪⃒"
    if name == "nLtv":
        return "≪̸"
    if name == "nRightarrow":
        return "⇏"
    if name == "nVDash":
        return "⊯"
    if name == "nVdash":
        return "⊮"
    if name == "nabla":
        return "∇"
    if name == "nacute":
        return "ń"
    if name == "nang":
        return "∠⃒"
    if name == "nap":
        return "≉"
    if name == "napE":
        return "⩰̸"
    if name == "napid":
        return "≋̸"
    if name == "napos":
        return "ŉ"
    if name == "napprox":
        return "≉"
    if name == "natur":
        return "♮"
    if name == "natural":
        return "♮"
    if name == "naturals":
        return "ℕ"
    if name == "nbsp":
        return " "
    if name == "nbump":
        return "≎̸"
    if name == "nbumpe":
        return "≏̸"
    if name == "ncap":
        return "⩃"
    if name == "ncaron":
        return "ň"
    if name == "ncedil":
        return "ņ"
    if name == "ncong":
        return "≇"
    if name == "ncongdot":
        return "⩭̸"
    if name == "ncup":
        return "⩂"
    if name == "ncy":
        return "н"
    if name == "ndash":
        return "–"
    if name == "ne":
        return "≠"
    if name == "neArr":
        return "⇗"
    if name == "nearhk":
        return "⤤"
    if name == "nearr":
        return "↗"
    if name == "nearrow":
        return "↗"
    if name == "nedot":
        return "≐̸"
    if name == "nequiv":
        return "≢"
    if name == "nesear":
        return "⤨"
    if name == "nesim":
        return "≂̸"
    if name == "nexist":
        return "∄"
    if name == "nexists":
        return "∄"
    if name == "nfr":
        return "𝔫"
    if name == "ngE":
        return "≧̸"
    if name == "nge":
        return "≱"
    if name == "ngeq":
        return "≱"
    if name == "ngeqq":
        return "≧̸"
    if name == "ngeqslant":
        return "⩾̸"
    if name == "nges":
        return "⩾̸"
    if name == "ngsim":
        return "≵"
    if name == "ngt":
        return "≯"
    if name == "ngtr":
        return "≯"
    if name == "nhArr":
        return "⇎"
    if name == "nharr":
        return "↮"
    if name == "nhpar":
        return "⫲"
    if name == "ni":
        return "∋"
    if name == "nis":
        return "⋼"
    if name == "nisd":
        return "⋺"
    if name == "niv":
        return "∋"
    if name == "njcy":
        return "њ"
    if name == "nlArr":
        return "⇍"
    if name == "nlE":
        return "≦̸"
    if name == "nlarr":
        return "↚"
    if name == "nldr":
        return "‥"
    if name == "nle":
        return "≰"
    if name == "nleftarrow":
        return "↚"
    if name == "nleftrightarrow":
        return "↮"
    if name == "nleq":
        return "≰"
    if name == "nleqq":
        return "≦̸"
    if name == "nleqslant":
        return "⩽̸"
    if name == "nles":
        return "⩽̸"
    if name == "nless":
        return "≮"
    if name == "nlsim":
        return "≴"
    if name == "nlt":
        return "≮"
    if name == "nltri":
        return "⋪"
    if name == "nltrie":
        return "⋬"
    if name == "nmid":
        return "∤"
    if name == "nopf":
        return "𝕟"
    if name == "not":
        return "¬"
    if name == "notin":
        return "∉"
    if name == "notinE":
        return "⋹̸"
    if name == "notindot":
        return "⋵̸"
    if name == "notinva":
        return "∉"
    if name == "notinvb":
        return "⋷"
    if name == "notinvc":
        return "⋶"
    if name == "notni":
        return "∌"
    if name == "notniva":
        return "∌"
    if name == "notnivb":
        return "⋾"
    if name == "notnivc":
        return "⋽"
    if name == "npar":
        return "∦"
    if name == "nparallel":
        return "∦"
    if name == "nparsl":
        return "⫽⃥"
    if name == "npart":
        return "∂̸"
    if name == "npolint":
        return "⨔"
    if name == "npr":
        return "⊀"
    if name == "nprcue":
        return "⋠"
    if name == "npre":
        return "⪯̸"
    if name == "nprec":
        return "⊀"
    if name == "npreceq":
        return "⪯̸"
    if name == "nrArr":
        return "⇏"
    if name == "nrarr":
        return "↛"
    if name == "nrarrc":
        return "⤳̸"
    if name == "nrarrw":
        return "↝̸"
    if name == "nrightarrow":
        return "↛"
    if name == "nrtri":
        return "⋫"
    if name == "nrtrie":
        return "⋭"
    if name == "nsc":
        return "⊁"
    if name == "nsccue":
        return "⋡"
    if name == "nsce":
        return "⪰̸"
    if name == "nscr":
        return "𝓃"
    if name == "nshortmid":
        return "∤"
    if name == "nshortparallel":
        return "∦"
    if name == "nsim":
        return "≁"
    if name == "nsime":
        return "≄"
    if name == "nsimeq":
        return "≄"
    if name == "nsmid":
        return "∤"
    if name == "nspar":
        return "∦"
    if name == "nsqsube":
        return "⋢"
    if name == "nsqsupe":
        return "⋣"
    if name == "nsub":
        return "⊄"
    if name == "nsubE":
        return "⫅̸"
    if name == "nsube":
        return "⊈"
    if name == "nsubset":
        return "⊂⃒"
    if name == "nsubseteq":
        return "⊈"
    if name == "nsubseteqq":
        return "⫅̸"
    if name == "nsucc":
        return "⊁"
    if name == "nsucceq":
        return "⪰̸"
    if name == "nsup":
        return "⊅"
    if name == "nsupE":
        return "⫆̸"
    if name == "nsupe":
        return "⊉"
    if name == "nsupset":
        return "⊃⃒"
    if name == "nsupseteq":
        return "⊉"
    if name == "nsupseteqq":
        return "⫆̸"
    if name == "ntgl":
        return "≹"
    if name == "ntilde":
        return "ñ"
    if name == "ntlg":
        return "≸"
    if name == "ntriangleleft":
        return "⋪"
    if name == "ntrianglelefteq":
        return "⋬"
    if name == "ntriangleright":
        return "⋫"
    if name == "ntrianglerighteq":
        return "⋭"
    if name == "nu":
        return "ν"
    if name == "num":
        return "#"
    if name == "numero":
        return "№"
    if name == "numsp":
        return " "
    if name == "nvDash":
        return "⊭"
    if name == "nvHarr":
        return "⤄"
    if name == "nvap":
        return "≍⃒"
    if name == "nvdash":
        return "⊬"
    if name == "nvge":
        return "≥⃒"
    if name == "nvgt":
        return ">⃒"
    if name == "nvinfin":
        return "⧞"
    if name == "nvlArr":
        return "⤂"
    if name == "nvle":
        return "≤⃒"
    if name == "nvlt":
        return "<⃒"
    if name == "nvltrie":
        return "⊴⃒"
    if name == "nvrArr":
        return "⤃"
    if name == "nvrtrie":
        return "⊵⃒"
    if name == "nvsim":
        return "∼⃒"
    if name == "nwArr":
        return "⇖"
    if name == "nwarhk":
        return "⤣"
    if name == "nwarr":
        return "↖"
    if name == "nwarrow":
        return "↖"
    if name == "nwnear":
        return "⤧"
    if name == "oS":
        return "Ⓢ"
    if name == "oacute":
        return "ó"
    if name == "oast":
        return "⊛"
    if name == "ocir":
        return "⊚"
    if name == "ocirc":
        return "ô"
    if name == "ocy":
        return "о"
    if name == "odash":
        return "⊝"
    if name == "odblac":
        return "ő"
    if name == "odiv":
        return "⨸"
    if name == "odot":
        return "⊙"
    if name == "odsold":
        return "⦼"
    if name == "oelig":
        return "œ"
    if name == "ofcir":
        return "⦿"
    if name == "ofr":
        return "𝔬"
    if name == "ogon":
        return "˛"
    if name == "ograve":
        return "ò"
    if name == "ogt":
        return "⧁"
    if name == "ohbar":
        return "⦵"
    if name == "ohm":
        return "Ω"
    if name == "oint":
        return "∮"
    if name == "olarr":
        return "↺"
    if name == "olcir":
        return "⦾"
    if name == "olcross":
        return "⦻"
    if name == "oline":
        return "‾"
    if name == "olt":
        return "⧀"
    if name == "omacr":
        return "ō"
    if name == "omega":
        return "ω"
    if name == "omicron":
        return "ο"
    if name == "omid":
        return "⦶"
    if name == "ominus":
        return "⊖"
    if name == "oopf":
        return "𝕠"
    if name == "opar":
        return "⦷"
    if name == "operp":
        return "⦹"
    if name == "oplus":
        return "⊕"
    if name == "or":
        return "∨"
    if name == "orarr":
        return "↻"
    if name == "ord":
        return "⩝"
    if name == "order":
        return "ℴ"
    if name == "orderof":
        return "ℴ"
    if name == "ordf":
        return "ª"
    if name == "ordm":
        return "º"
    if name == "origof":
        return "⊶"
    if name == "oror":
        return "⩖"
    if name == "orslope":
        return "⩗"
    if name == "orv":
        return "⩛"
    if name == "oscr":
        return "ℴ"
    if name == "oslash":
        return "ø"
    if name == "osol":
        return "⊘"
    if name == "otilde":
        return "õ"
    if name == "otimes":
        return "⊗"
    if name == "otimesas":
        return "⨶"
    if name == "ouml":
        return "ö"
    if name == "ovbar":
        return "⌽"
    if name == "par":
        return "∥"
    if name == "para":
        return "¶"
    if name == "parallel":
        return "∥"
    if name == "parsim":
        return "⫳"
    if name == "parsl":
        return "⫽"
    if name == "part":
        return "∂"
    if name == "pcy":
        return "п"
    if name == "percnt":
        return "%"
    if name == "period":
        return "."
    if name == "permil":
        return "‰"
    if name == "perp":
        return "⊥"
    if name == "pertenk":
        return "‱"
    if name == "pfr":
        return "𝔭"
    if name == "phi":
        return "φ"
    if name == "phiv":
        return "ϕ"
    if name == "phmmat":
        return "ℳ"
    if name == "phone":
        return "☎"
    if name == "pi":
        return "π"
    if name == "pitchfork":
        return "⋔"
    if name == "piv":
        return "ϖ"
    if name == "planck":
        return "ℏ"
    if name == "planckh":
        return "ℎ"
    if name == "plankv":
        return "ℏ"
    if name == "plus":
        return "+"
    if name == "plusacir":
        return "⨣"
    if name == "plusb":
        return "⊞"
    if name == "pluscir":
        return "⨢"
    if name == "plusdo":
        return "∔"
    if name == "plusdu":
        return "⨥"
    if name == "pluse":
        return "⩲"
    if name == "plusmn":
        return "±"
    if name == "plussim":
        return "⨦"
    if name == "plustwo":
        return "⨧"
    if name == "pm":
        return "±"
    if name == "pointint":
        return "⨕"
    if name == "popf":
        return "𝕡"
    if name == "pound":
        return "£"
    if name == "pr":
        return "≺"
    if name == "prE":
        return "⪳"
    if name == "prap":
        return "⪷"
    if name == "prcue":
        return "≼"
    if name == "pre":
        return "⪯"
    if name == "prec":
        return "≺"
    if name == "precapprox":
        return "⪷"
    if name == "preccurlyeq":
        return "≼"
    if name == "preceq":
        return "⪯"
    if name == "precnapprox":
        return "⪹"
    if name == "precneqq":
        return "⪵"
    if name == "precnsim":
        return "⋨"
    if name == "precsim":
        return "≾"
    if name == "prime":
        return "′"
    if name == "primes":
        return "ℙ"
    if name == "prnE":
        return "⪵"
    if name == "prnap":
        return "⪹"
    if name == "prnsim":
        return "⋨"
    if name == "prod":
        return "∏"
    if name == "profalar":
        return "⌮"
    if name == "profline":
        return "⌒"
    if name == "profsurf":
        return "⌓"
    if name == "prop":
        return "∝"
    if name == "propto":
        return "∝"
    if name == "prsim":
        return "≾"
    if name == "prurel":
        return "⊰"
    if name == "pscr":
        return "𝓅"
    if name == "psi":
        return "ψ"
    if name == "puncsp":
        return " "
    if name == "qfr":
        return "𝔮"
    if name == "qint":
        return "⨌"
    if name == "qopf":
        return "𝕢"
    if name == "qprime":
        return "⁗"
    if name == "qscr":
        return "𝓆"
    if name == "quaternions":
        return "ℍ"
    if name == "quatint":
        return "⨖"
    if name == "quest":
        return "?"
    if name == "questeq":
        return "≟"
    if name == "quot":
        return "\""
    if name == "rAarr":
        return "⇛"
    if name == "rArr":
        return "⇒"
    if name == "rAtail":
        return "⤜"
    if name == "rBarr":
        return "⤏"
    if name == "rHar":
        return "⥤"
    if name == "race":
        return "∽̱"
    if name == "racute":
        return "ŕ"
    if name == "radic":
        return "√"
    if name == "raemptyv":
        return "⦳"
    if name == "rang":
        return "⟩"
    if name == "rangd":
        return "⦒"
    if name == "range":
        return "⦥"
    if name == "rangle":
        return "⟩"
    if name == "raquo":
        return "»"
    if name == "rarr":
        return "→"
    if name == "rarrap":
        return "⥵"
    if name == "rarrb":
        return "⇥"
    if name == "rarrbfs":
        return "⤠"
    if name == "rarrc":
        return "⤳"
    if name == "rarrfs":
        return "⤞"
    if name == "rarrhk":
        return "↪"
    if name == "rarrlp":
        return "↬"
    if name == "rarrpl":
        return "⥅"
    if name == "rarrsim":
        return "⥴"
    if name == "rarrtl":
        return "↣"
    if name == "rarrw":
        return "↝"
    if name == "ratail":
        return "⤚"
    if name == "ratio":
        return "∶"
    if name == "rationals":
        return "ℚ"
    if name == "rbarr":
        return "⤍"
    if name == "rbbrk":
        return "❳"
    if name == "rbrace":
        return "}"
    if name == "rbrack":
        return "]"
    if name == "rbrke":
        return "⦌"
    if name == "rbrksld":
        return "⦎"
    if name == "rbrkslu":
        return "⦐"
    if name == "rcaron":
        return "ř"
    if name == "rcedil":
        return "ŗ"
    if name == "rceil":
        return "⌉"
    if name == "rcub":
        return "}"
    if name == "rcy":
        return "р"
    if name == "rdca":
        return "⤷"
    if name == "rdldhar":
        return "⥩"
    if name == "rdquo":
        return "”"
    if name == "rdquor":
        return "”"
    if name == "rdsh":
        return "↳"
    if name == "real":
        return "ℜ"
    if name == "realine":
        return "ℛ"
    if name == "realpart":
        return "ℜ"
    if name == "reals":
        return "ℝ"
    if name == "rect":
        return "▭"
    if name == "reg":
        return "®"
    if name == "rfisht":
        return "⥽"
    if name == "rfloor":
        return "⌋"
    if name == "rfr":
        return "𝔯"
    if name == "rhard":
        return "⇁"
    if name == "rharu":
        return "⇀"
    if name == "rharul":
        return "⥬"
    if name == "rho":
        return "ρ"
    if name == "rhov":
        return "ϱ"
    if name == "rightarrow":
        return "→"
    if name == "rightarrowtail":
        return "↣"
    if name == "rightharpoondown":
        return "⇁"
    if name == "rightharpoonup":
        return "⇀"
    if name == "rightleftarrows":
        return "⇄"
    if name == "rightleftharpoons":
        return "⇌"
    if name == "rightrightarrows":
        return "⇉"
    if name == "rightsquigarrow":
        return "↝"
    if name == "rightthreetimes":
        return "⋌"
    if name == "ring":
        return "˚"
    if name == "risingdotseq":
        return "≓"
    if name == "rlarr":
        return "⇄"
    if name == "rlhar":
        return "⇌"
    if name == "rlm":
        return "‏"
    if name == "rmoust":
        return "⎱"
    if name == "rmoustache":
        return "⎱"
    if name == "rnmid":
        return "⫮"
    if name == "roang":
        return "⟭"
    if name == "roarr":
        return "⇾"
    if name == "robrk":
        return "⟧"
    if name == "ropar":
        return "⦆"
    if name == "ropf":
        return "𝕣"
    if name == "roplus":
        return "⨮"
    if name == "rotimes":
        return "⨵"
    if name == "rpar":
        return ")"
    if name == "rpargt":
        return "⦔"
    if name == "rppolint":
        return "⨒"
    if name == "rrarr":
        return "⇉"
    if name == "rsaquo":
        return "›"
    if name == "rscr":
        return "𝓇"
    if name == "rsh":
        return "↱"
    if name == "rsqb":
        return "]"
    if name == "rsquo":
        return "’"
    if name == "rsquor":
        return "’"
    if name == "rthree":
        return "⋌"
    if name == "rtimes":
        return "⋊"
    if name == "rtri":
        return "▹"
    if name == "rtrie":
        return "⊵"
    if name == "rtrif":
        return "▸"
    if name == "rtriltri":
        return "⧎"
    if name == "ruluhar":
        return "⥨"
    if name == "rx":
        return "℞"
    if name == "sacute":
        return "ś"
    if name == "sbquo":
        return "‚"
    if name == "sc":
        return "≻"
    if name == "scE":
        return "⪴"
    if name == "scap":
        return "⪸"
    if name == "scaron":
        return "š"
    if name == "sccue":
        return "≽"
    if name == "sce":
        return "⪰"
    if name == "scedil":
        return "ş"
    if name == "scirc":
        return "ŝ"
    if name == "scnE":
        return "⪶"
    if name == "scnap":
        return "⪺"
    if name == "scnsim":
        return "⋩"
    if name == "scpolint":
        return "⨓"
    if name == "scsim":
        return "≿"
    if name == "scy":
        return "с"
    if name == "sdot":
        return "⋅"
    if name == "sdotb":
        return "⊡"
    if name == "sdote":
        return "⩦"
    if name == "seArr":
        return "⇘"
    if name == "searhk":
        return "⤥"
    if name == "searr":
        return "↘"
    if name == "searrow":
        return "↘"
    if name == "sect":
        return "§"
    if name == "semi":
        return ";"
    if name == "seswar":
        return "⤩"
    if name == "setminus":
        return "∖"
    if name == "setmn":
        return "∖"
    if name == "sext":
        return "✶"
    if name == "sfr":
        return "𝔰"
    if name == "sfrown":
        return "⌢"
    if name == "sharp":
        return "♯"
    if name == "shchcy":
        return "щ"
    if name == "shcy":
        return "ш"
    if name == "shortmid":
        return "∣"
    if name == "shortparallel":
        return "∥"
    if name == "shy":
        return "­"
    if name == "sigma":
        return "σ"
    if name == "sigmaf":
        return "ς"
    if name == "sigmav":
        return "ς"
    if name == "sim":
        return "∼"
    if name == "simdot":
        return "⩪"
    if name == "sime":
        return "≃"
    if name == "simeq":
        return "≃"
    if name == "simg":
        return "⪞"
    if name == "simgE":
        return "⪠"
    if name == "siml":
        return "⪝"
    if name == "simlE":
        return "⪟"
    if name == "simne":
        return "≆"
    if name == "simplus":
        return "⨤"
    if name == "simrarr":
        return "⥲"
    if name == "slarr":
        return "←"
    if name == "smallsetminus":
        return "∖"
    if name == "smashp":
        return "⨳"
    if name == "smeparsl":
        return "⧤"
    if name == "smid":
        return "∣"
    if name == "smile":
        return "⌣"
    if name == "smt":
        return "⪪"
    if name == "smte":
        return "⪬"
    if name == "smtes":
        return "⪬︀"
    if name == "softcy":
        return "ь"
    if name == "sol":
        return "/"
    if name == "solb":
        return "⧄"
    if name == "solbar":
        return "⌿"
    if name == "sopf":
        return "𝕤"
    if name == "spades":
        return "♠"
    if name == "spadesuit":
        return "♠"
    if name == "spar":
        return "∥"
    if name == "sqcap":
        return "⊓"
    if name == "sqcaps":
        return "⊓︀"
    if name == "sqcup":
        return "⊔"
    if name == "sqcups":
        return "⊔︀"
    if name == "sqsub":
        return "⊏"
    if name == "sqsube":
        return "⊑"
    if name == "sqsubset":
        return "⊏"
    if name == "sqsubseteq":
        return "⊑"
    if name == "sqsup":
        return "⊐"
    if name == "sqsupe":
        return "⊒"
    if name == "sqsupset":
        return "⊐"
    if name == "sqsupseteq":
        return "⊒"
    if name == "squ":
        return "□"
    if name == "square":
        return "□"
    if name == "squarf":
        return "▪"
    if name == "squf":
        return "▪"
    if name == "srarr":
        return "→"
    if name == "sscr":
        return "𝓈"
    if name == "ssetmn":
        return "∖"
    if name == "ssmile":
        return "⌣"
    if name == "sstarf":
        return "⋆"
    if name == "star":
        return "☆"
    if name == "starf":
        return "★"
    if name == "straightepsilon":
        return "ϵ"
    if name == "straightphi":
        return "ϕ"
    if name == "strns":
        return "¯"
    if name == "sub":
        return "⊂"
    if name == "subE":
        return "⫅"
    if name == "subdot":
        return "⪽"
    if name == "sube":
        return "⊆"
    if name == "subedot":
        return "⫃"
    if name == "submult":
        return "⫁"
    if name == "subnE":
        return "⫋"
    if name == "subne":
        return "⊊"
    if name == "subplus":
        return "⪿"
    if name == "subrarr":
        return "⥹"
    if name == "subset":
        return "⊂"
    if name == "subseteq":
        return "⊆"
    if name == "subseteqq":
        return "⫅"
    if name == "subsetneq":
        return "⊊"
    if name == "subsetneqq":
        return "⫋"
    if name == "subsim":
        return "⫇"
    if name == "subsub":
        return "⫕"
    if name == "subsup":
        return "⫓"
    if name == "succ":
        return "≻"
    if name == "succapprox":
        return "⪸"
    if name == "succcurlyeq":
        return "≽"
    if name == "succeq":
        return "⪰"
    if name == "succnapprox":
        return "⪺"
    if name == "succneqq":
        return "⪶"
    if name == "succnsim":
        return "⋩"
    if name == "succsim":
        return "≿"
    if name == "sum":
        return "∑"
    if name == "sung":
        return "♪"
    if name == "sup":
        return "⊃"
    if name == "sup1":
        return "¹"
    if name == "sup2":
        return "²"
    if name == "sup3":
        return "³"
    if name == "supE":
        return "⫆"
    if name == "supdot":
        return "⪾"
    if name == "supdsub":
        return "⫘"
    if name == "supe":
        return "⊇"
    if name == "supedot":
        return "⫄"
    if name == "suphsol":
        return "⟉"
    if name == "suphsub":
        return "⫗"
    if name == "suplarr":
        return "⥻"
    if name == "supmult":
        return "⫂"
    if name == "supnE":
        return "⫌"
    if name == "supne":
        return "⊋"
    if name == "supplus":
        return "⫀"
    if name == "supset":
        return "⊃"
    if name == "supseteq":
        return "⊇"
    if name == "supseteqq":
        return "⫆"
    if name == "supsetneq":
        return "⊋"
    if name == "supsetneqq":
        return "⫌"
    if name == "supsim":
        return "⫈"
    if name == "supsub":
        return "⫔"
    if name == "supsup":
        return "⫖"
    if name == "swArr":
        return "⇙"
    if name == "swarhk":
        return "⤦"
    if name == "swarr":
        return "↙"
    if name == "swarrow":
        return "↙"
    if name == "swnwar":
        return "⤪"
    if name == "szlig":
        return "ß"
    if name == "target":
        return "⌖"
    if name == "tau":
        return "τ"
    if name == "tbrk":
        return "⎴"
    if name == "tcaron":
        return "ť"
    if name == "tcedil":
        return "ţ"
    if name == "tcy":
        return "т"
    if name == "tdot":
        return "⃛"
    if name == "telrec":
        return "⌕"
    if name == "tfr":
        return "𝔱"
    if name == "there4":
        return "∴"
    if name == "therefore":
        return "∴"
    if name == "theta":
        return "θ"
    if name == "thetasym":
        return "ϑ"
    if name == "thetav":
        return "ϑ"
    if name == "thickapprox":
        return "≈"
    if name == "thicksim":
        return "∼"
    if name == "thinsp":
        return " "
    if name == "thkap":
        return "≈"
    if name == "thksim":
        return "∼"
    if name == "thorn":
        return "þ"
    if name == "tilde":
        return "˜"
    if name == "times":
        return "×"
    if name == "timesb":
        return "⊠"
    if name == "timesbar":
        return "⨱"
    if name == "timesd":
        return "⨰"
    if name == "tint":
        return "∭"
    if name == "toea":
        return "⤨"
    if name == "top":
        return "⊤"
    if name == "topbot":
        return "⌶"
    if name == "topcir":
        return "⫱"
    if name == "topf":
        return "𝕥"
    if name == "topfork":
        return "⫚"
    if name == "tosa":
        return "⤩"
    if name == "tprime":
        return "‴"
    if name == "trade":
        return "™"
    if name == "triangle":
        return "▵"
    if name == "triangledown":
        return "▿"
    if name == "triangleleft":
        return "◃"
    if name == "trianglelefteq":
        return "⊴"
    if name == "triangleq":
        return "≜"
    if name == "triangleright":
        return "▹"
    if name == "trianglerighteq":
        return "⊵"
    if name == "tridot":
        return "◬"
    if name == "trie":
        return "≜"
    if name == "triminus":
        return "⨺"
    if name == "triplus":
        return "⨹"
    if name == "trisb":
        return "⧍"
    if name == "tritime":
        return "⨻"
    if name == "trpezium":
        return "⏢"
    if name == "tscr":
        return "𝓉"
    if name == "tscy":
        return "ц"
    if name == "tshcy":
        return "ћ"
    if name == "tstrok":
        return "ŧ"
    if name == "twixt":
        return "≬"
    if name == "twoheadleftarrow":
        return "↞"
    if name == "twoheadrightarrow":
        return "↠"
    if name == "uArr":
        return "⇑"
    if name == "uHar":
        return "⥣"
    if name == "uacute":
        return "ú"
    if name == "uarr":
        return "↑"
    if name == "ubrcy":
        return "ў"
    if name == "ubreve":
        return "ŭ"
    if name == "ucirc":
        return "û"
    if name == "ucy":
        return "у"
    if name == "udarr":
        return "⇅"
    if name == "udblac":
        return "ű"
    if name == "udhar":
        return "⥮"
    if name == "ufisht":
        return "⥾"
    if name == "ufr":
        return "𝔲"
    if name == "ugrave":
        return "ù"
    if name == "uharl":
        return "↿"
    if name == "uharr":
        return "↾"
    if name == "uhblk":
        return "▀"
    if name == "ulcorn":
        return "⌜"
    if name == "ulcorner":
        return "⌜"
    if name == "ulcrop":
        return "⌏"
    if name == "ultri":
        return "◸"
    if name == "umacr":
        return "ū"
    if name == "uml":
        return "¨"
    if name == "uogon":
        return "ų"
    if name == "uopf":
        return "𝕦"
    if name == "uparrow":
        return "↑"
    if name == "updownarrow":
        return "↕"
    if name == "upharpoonleft":
        return "↿"
    if name == "upharpoonright":
        return "↾"
    if name == "uplus":
        return "⊎"
    if name == "upsi":
        return "υ"
    if name == "upsih":
        return "ϒ"
    if name == "upsilon":
        return "υ"
    if name == "upuparrows":
        return "⇈"
    if name == "urcorn":
        return "⌝"
    if name == "urcorner":
        return "⌝"
    if name == "urcrop":
        return "⌎"
    if name == "uring":
        return "ů"
    if name == "urtri":
        return "◹"
    if name == "uscr":
        return "𝓊"
    if name == "utdot":
        return "⋰"
    if name == "utilde":
        return "ũ"
    if name == "utri":
        return "▵"
    if name == "utrif":
        return "▴"
    if name == "uuarr":
        return "⇈"
    if name == "uuml":
        return "ü"
    if name == "uwangle":
        return "⦧"
    if name == "vArr":
        return "⇕"
    if name == "vBar":
        return "⫨"
    if name == "vBarv":
        return "⫩"
    if name == "vDash":
        return "⊨"
    if name == "vangrt":
        return "⦜"
    if name == "varepsilon":
        return "ϵ"
    if name == "varkappa":
        return "ϰ"
    if name == "varnothing":
        return "∅"
    if name == "varphi":
        return "ϕ"
    if name == "varpi":
        return "ϖ"
    if name == "varpropto":
        return "∝"
    if name == "varr":
        return "↕"
    if name == "varrho":
        return "ϱ"
    if name == "varsigma":
        return "ς"
    if name == "varsubsetneq":
        return "⊊︀"
    if name == "varsubsetneqq":
        return "⫋︀"
    if name == "varsupsetneq":
        return "⊋︀"
    if name == "varsupsetneqq":
        return "⫌︀"
    if name == "vartheta":
        return "ϑ"
    if name == "vartriangleleft":
        return "⊲"
    if name == "vartriangleright":
        return "⊳"
    if name == "vcy":
        return "в"
    if name == "vdash":
        return "⊢"
    if name == "vee":
        return "∨"
    if name == "veebar":
        return "⊻"
    if name == "veeeq":
        return "≚"
    if name == "vellip":
        return "⋮"
    if name == "verbar":
        return "|"
    if name == "vert":
        return "|"
    if name == "vfr":
        return "𝔳"
    if name == "vltri":
        return "⊲"
    if name == "vnsub":
        return "⊂⃒"
    if name == "vnsup":
        return "⊃⃒"
    if name == "vopf":
        return "𝕧"
    if name == "vprop":
        return "∝"
    if name == "vrtri":
        return "⊳"
    if name == "vscr":
        return "𝓋"
    if name == "vsubnE":
        return "⫋︀"
    if name == "vsubne":
        return "⊊︀"
    if name == "vsupnE":
        return "⫌︀"
    if name == "vsupne":
        return "⊋︀"
    if name == "vzigzag":
        return "⦚"
    if name == "wcirc":
        return "ŵ"
    if name == "wedbar":
        return "⩟"
    if name == "wedge":
        return "∧"
    if name == "wedgeq":
        return "≙"
    if name == "weierp":
        return "℘"
    if name == "wfr":
        return "𝔴"
    if name == "wopf":
        return "𝕨"
    if name == "wp":
        return "℘"
    if name == "wr":
        return "≀"
    if name == "wreath":
        return "≀"
    if name == "wscr":
        return "𝓌"
    if name == "xcap":
        return "⋂"
    if name == "xcirc":
        return "◯"
    if name == "xcup":
        return "⋃"
    if name == "xdtri":
        return "▽"
    if name == "xfr":
        return "𝔵"
    if name == "xhArr":
        return "⟺"
    if name == "xharr":
        return "⟷"
    if name == "xi":
        return "ξ"
    if name == "xlArr":
        return "⟸"
    if name == "xlarr":
        return "⟵"
    if name == "xmap":
        return "⟼"
    if name == "xnis":
        return "⋻"
    if name == "xodot":
        return "⨀"
    if name == "xopf":
        return "𝕩"
    if name == "xoplus":
        return "⨁"
    if name == "xotime":
        return "⨂"
    if name == "xrArr":
        return "⟹"
    if name == "xrarr":
        return "⟶"
    if name == "xscr":
        return "𝓍"
    if name == "xsqcup":
        return "⨆"
    if name == "xuplus":
        return "⨄"
    if name == "xutri":
        return "△"
    if name == "xvee":
        return "⋁"
    if name == "xwedge":
        return "⋀"
    if name == "yacute":
        return "ý"
    if name == "yacy":
        return "я"
    if name == "ycirc":
        return "ŷ"
    if name == "ycy":
        return "ы"
    if name == "yen":
        return "¥"
    if name == "yfr":
        return "𝔶"
    if name == "yicy":
        return "ї"
    if name == "yopf":
        return "𝕪"
    if name == "yscr":
        return "𝓎"
    if name == "yucy":
        return "ю"
    if name == "yuml":
        return "ÿ"
    if name == "zacute":
        return "ź"
    if name == "zcaron":
        return "ž"
    if name == "zcy":
        return "з"
    if name == "zdot":
        return "ż"
    if name == "zeetrf":
        return "ℨ"
    if name == "zeta":
        return "ζ"
    if name == "zfr":
        return "𝔷"
    if name == "zhcy":
        return "ж"
    if name == "zigrarr":
        return "⇝"
    if name == "zopf":
        return "𝕫"
    if name == "zscr":
        return "𝓏"
    if name == "zwj":
        return "‍"
    if name == "zwnj":
        return "‌"
    return ""
def _c1_map(cp: Int) -> Int:
    """The HTML Windows-1252 replacements for C1 numeric references
    (0x80-0x9F); unlisted entries keep their own value."""
    if cp == 0x80:
        return 0x20AC
    if cp == 0x82:
        return 0x201A
    if cp == 0x83:
        return 0x0192
    if cp == 0x84:
        return 0x201E
    if cp == 0x85:
        return 0x2026
    if cp == 0x86:
        return 0x2020
    if cp == 0x87:
        return 0x2021
    if cp == 0x88:
        return 0x02C6
    if cp == 0x89:
        return 0x2030
    if cp == 0x8A:
        return 0x0160
    if cp == 0x8B:
        return 0x2039
    if cp == 0x8C:
        return 0x0152
    if cp == 0x8E:
        return 0x017D
    if cp == 0x91:
        return 0x2018
    if cp == 0x92:
        return 0x2019
    if cp == 0x93:
        return 0x201C
    if cp == 0x94:
        return 0x201D
    if cp == 0x95:
        return 0x2022
    if cp == 0x96:
        return 0x2013
    if cp == 0x97:
        return 0x2014
    if cp == 0x98:
        return 0x02DC
    if cp == 0x99:
        return 0x2122
    if cp == 0x9A:
        return 0x0161
    if cp == 0x9B:
        return 0x203A
    if cp == 0x9C:
        return 0x0153
    if cp == 0x9E:
        return 0x017E
    if cp == 0x9F:
        return 0x0178
    return cp


def _decode_codepoint(cp: Int) -> String:
    if cp == 0 or cp > 0x10FFFF or (0xD800 <= cp and cp <= 0xDFFF):
        return "�"
    var v = cp
    if 0x80 <= cp and cp <= 0x9F:
        # HTML numeric references in the C1 range map through the
        # Windows-1252 replacements.
        v = _c1_map(cp)
    var buf = List[UInt8]()
    if v < 0x80:
        buf.append(UInt8(v))
    elif v < 0x800:
        buf.append(UInt8(0xC0 | (v >> 6)))
        buf.append(UInt8(0x80 | (v & 0x3F)))
    elif v < 0x10000:
        buf.append(UInt8(0xE0 | (v >> 12)))
        buf.append(UInt8(0x80 | ((v >> 6) & 0x3F)))
        buf.append(UInt8(0x80 | (v & 0x3F)))
    else:
        buf.append(UInt8(0xF0 | (v >> 18)))
        buf.append(UInt8(0x80 | ((v >> 12) & 0x3F)))
        buf.append(UInt8(0x80 | ((v >> 6) & 0x3F)))
        buf.append(UInt8(0x80 | (v & 0x3F)))
    return String(StringSlice(unsafe_from_utf8=Span(buf)))


def _find_backtick_close(s: String, start: Int, run: Int) -> Int:
    var bytes = s.as_bytes()
    var i = start
    while i < len(bytes):
        if bytes[i] == 0x60:
            var r = 0
            var j = i
            while j < len(bytes) and bytes[j] == 0x60:
                r += 1
                j += 1
            if r == run:
                return i
            i = j
            continue
        i += 1
    return -1


def _find_bracket_close(s: String, start: Int) -> Int:
    """Index of the ']' matching the '[' just before `start` (nesting-aware,
    skipping code spans and escapes)."""
    var bytes = s.as_bytes()
    var depth = 1
    var i = start
    while i < len(bytes):
        var b = bytes[i]
        if b == 0x5C and i + 1 < len(bytes):
            i += 2
            continue
        if b == 0x60:
            var run = 1
            var j = i + 1
            while j < len(bytes) and bytes[j] == 0x60:
                run += 1
                j += 1
            var close = _find_backtick_close(s, j, run)
            i = close + run if close != -1 else j
            continue
        if b == 0x5B:
            depth += 1
        elif b == 0x5D:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def _link_html(
    dest: String, title: String, text_html: String, image: Bool
) -> String:
    var d = _unescape_backslash(_decode_entities(dest))
    var ti = _unescape_backslash(_decode_entities(title))
    if image:
        var out = '<img src="' + escape_attr(encode_uri(d)) + '" alt="'
        out += escape_attr(text_html) + '"'
        if ti != "":
            out += ' title="' + escape_attr(ti) + '"'
        return out + " />"
    var out2 = '<a href="' + escape_attr(encode_uri(d)) + '"'
    if ti != "":
        out2 += ' title="' + escape_attr(ti) + '"'
    return out2 + ">" + text_html + "</a>"


def _autolink_html(dest: String, display: String) -> String:
    """An autolink: the destination between the brackets is literal
    (no backslash processing); the display text is the address or
    URI itself."""
    var out = '<a href="' + escape_attr(encode_uri(_decode_entities(dest))) + '">'
    return out + escape_text(display) + "</a>"


def _scan_tag(s: String, start: Int) -> Int:
    """Match an HTML tag at the '<' at `start` per the spec's tag
    grammar (open and closing tags, attributes with unquoted, single-
    or double-quoted values; values and inter-attribute whitespace
    may span lines). Returns the index just past '>', or -1."""
    var bytes = s.as_bytes()
    var n = len(bytes)
    var i = start + 1
    if i < n and bytes[i] == 0x2F:
        # Closing tag: </name whitespace* >
        i += 1
        if i >= n or not _is_alpha(bytes[i]):
            return -1
        while i < n and (_is_alpha(bytes[i]) or _is_digit(bytes[i]) or bytes[i] == 0x2D):
            i += 1
        while i < n and _is_space(bytes[i]):
            i += 1
        if i < n and bytes[i] == 0x3E:
            return i + 1
        return -1
    if i >= n or not _is_alpha(bytes[i]):
        return -1
    while i < n and (_is_alpha(bytes[i]) or _is_digit(bytes[i]) or bytes[i] == 0x2D):
        i += 1
    while True:
        # Between the tag name / an attribute and the next: whitespace.
        var j = i
        while j < n and _is_space(bytes[j]):
            j += 1
        if j >= n:
            return -1
        if bytes[j] == 0x3E:
            return j + 1
        if bytes[j] == 0x2F and j + 1 < n and bytes[j + 1] == 0x3E:
            return j + 2
        if j == i:
            return -1  # attributes must be whitespace-separated
        i = j
        # Attribute name.
        if not (_is_alpha(bytes[i]) or bytes[i] == 0x5F or bytes[i] == 0x3A):
            return -1
        i += 1
        while i < n and (
            _is_alpha(bytes[i])
            or _is_digit(bytes[i])
            or bytes[i] == 0x5F
            or bytes[i] == 0x2E
            or bytes[i] == 0x3A
            or bytes[i] == 0x2D
        ):
            i += 1
        # Optional = value.
        var k = i
        while k < n and _is_space(bytes[k]):
            k += 1
        if k < n and bytes[k] == 0x3D:
            k += 1
            while k < n and _is_space(bytes[k]):
                k += 1
            if k >= n:
                return -1
            if bytes[k] == 0x22 or bytes[k] == 0x27:
                var q = bytes[k]
                k += 1
                while k < n and bytes[k] != q:
                    k += 1
                if k >= n:
                    return -1
                i = k + 1
            else:
                var v = k
                while v < n and not _is_space(bytes[v]):
                    var vb = bytes[v]
                    if vb == 0x22 or vb == 0x27 or vb == 0x3D or vb == 0x3C or vb == 0x3E or vb == 0x60:
                        return -1
                    v += 1
                if v == k:
                    return -1
                i = v


def _scan_autolink(s: String, start: Int) -> Tuple[Int, String, Bool]:
    """Match an autolink at the '<' at `start`: <scheme:...> or an
    email address. Returns (end index, destination, is_email), with
    end == -1 when there is no autolink here."""
    var bytes = s.as_bytes()
    var n = len(bytes)
    var i = start + 1
    # URI autolink: scheme is 2-32 chars, letter first.
    var j = i
    if j < n and _is_alpha(bytes[j]):
        j += 1
        while j < n and (
            _is_alpha(bytes[j])
            or _is_digit(bytes[j])
            or bytes[j] == 0x2B
            or bytes[j] == 0x2E
            or bytes[j] == 0x2D
        ):
            j += 1
        if 2 <= j - i and j - i <= 32 and j < n and bytes[j] == 0x3A:
            var k = j + 1
            var ok = True
            while k < n and bytes[k] != 0x3E:
                var b = bytes[k]
                if b <= UInt8(0x20) or b == 0x3C:
                    ok = False
                    break
                k += 1
            if ok and k < n:
                return (k + 1, _sub(s, i, k), False)
    # Email autolink.
    var at = -1
    var k2 = i
    while k2 < n and bytes[k2] != 0x3E:
        var b = bytes[k2]
        if b == 0x40:
            if at != -1:
                return (-1, String(), False)
            at = k2
        if b <= UInt8(0x20) or b == 0x3C:
            return (-1, String(), False)
        k2 += 1
    if k2 >= n or at <= i:
        return (-1, String(), False)
    var local = _sub(s, i, at)
    var domain = _sub(s, at + 1, k2)
    for b in local.as_bytes():
        var okc = (
            _is_alpha(b)
            or _is_digit(b)
            or b == 0x2E or b == 0x21 or b == 0x23 or b == 0x24 or b == 0x25
            or b == 0x26 or b == 0x27 or b == 0x2A or b == 0x2B or b == 0x2D
            or b == 0x2F or b == 0x3D or b == 0x3F or b == 0x5E or b == 0x5F
            or b == 0x60 or b == 0x7B or b == 0x7C or b == 0x7D or b == 0x7E
        )
        if not okc:
            return (-1, String(), False)
    var labels = domain.split(".")
    if len(labels) < 2:
        return (-1, String(), False)
    for ref lab in labels:
        var lb = lab.as_bytes()
        if len(lb) == 0 or lb[0] == 0x2D or lb[len(lb) - 1] == 0x2D:
            return (-1, String(), False)
        for b in lb:
            if not (_is_alpha(b) or _is_digit(b) or b == 0x2D):
                return (-1, String(), False)
    return (k2 + 1, _sub(s, i, k2), True)


def _decode_cp(s: String, pos: Int) -> Tuple[Int, Int]:
    """Decode the UTF-8 codepoint starting at byte `pos`.
    Returns (codepoint, byte length); invalid bytes decode as their
    own value with length 1."""
    var bytes = s.as_bytes()
    var b0 = bytes[pos]
    if b0 < 0x80:
        return (Int(b0), 1)
    var need = 0
    var cp = 0
    if b0 >= 0xF0:
        need = 3
        cp = Int(b0 & 0x07)
    elif b0 >= 0xE0:
        need = 2
        cp = Int(b0 & 0x0F)
    elif b0 >= 0xC0:
        need = 1
        cp = Int(b0 & 0x1F)
    else:
        return (Int(b0), 1)
    if pos + need >= len(bytes):
        return (Int(b0), 1)
    for k in range(1, need + 1):
        var bx = bytes[pos + k]
        if bx < 0x80 or bx >= 0xC0:
            return (Int(b0), 1)
        cp = (cp << 6) | Int(bx & 0x3F)
    return (cp, need + 1)


def _cp_before(s: String, pos: Int) -> Int:
    """The codepoint ending just before byte `pos`, or -1 at the
    start of the string."""
    if pos <= 0:
        return -1
    var bytes = s.as_bytes()
    var i = pos - 1
    var steps = 0
    while i > 0 and bytes[i] >= 0x80 and bytes[i] < 0xC0 and steps < 3:
        i -= 1
        steps += 1
    return _decode_cp(s, i)[0]


def _cp_is_space(cp: Int) -> Bool:
    """The Unicode White_Space property (the spec's whitespace for
    flanking and label matching)."""
    if cp == 0x09 or cp == 0x0A or cp == 0x0B or cp == 0x0C or cp == 0x0D or cp == 0x20:
        return True
    if cp == 0xA0 or cp == 0x1680 or cp == 0x2028 or cp == 0x2029 or cp == 0x202F or cp == 0x205F or cp == 0x3000:
        return True
    return 0x2000 <= cp and cp <= 0x200A


def _cp_is_punct(cp: Int) -> Bool:
    """Unicode general categories P and S — the set the reference
    implementations use for flanking (it is what makes a run after
    £ or € unable to close emphasis, per the corpus)."""
    if cp < 0x80:
        return _is_punct(UInt8(cp))
    if 0xA1 <= cp and cp <= 0xBF:
        # Exceptions in this range are letters, numbers, and marks.
        return not (
            cp == 0xAA or cp == 0xAD or cp == 0xB2 or cp == 0xB3 or cp == 0xB5
            or cp == 0xB9 or cp == 0xBA or cp == 0xBC or cp == 0xBD or cp == 0xBE
        )
    if 0x2010 <= cp and cp <= 0x2027:
        return True
    if 0x2030 <= cp and cp <= 0x205E:
        return True
    if 0x207A <= cp and cp <= 0x207D or 0x208A <= cp and cp <= 0x208D:
        return True
    if 0x20A0 <= cp and cp <= 0x20BF:
        return True  # currency symbols (Sc), incl. the euro sign
    if 0x2190 <= cp and cp <= 0x21FF:
        return True  # arrows (Sm/So)
    if 0x2200 <= cp and cp <= 0x22FF:
        return True  # mathematical operators (Sm)
    if 0x2300 <= cp and cp <= 0x23FF:
        return True  # technical symbols (So/Sk)
    if 0x2500 <= cp and cp <= 0x2BFF:
        return True  # shapes, dingbats (So-heavy)
    if 0x3001 <= cp and cp <= 0x303F:
        return True  # CJK punctuation
    if 0xFE30 <= cp and cp <= 0xFE6F:
        return True
    if 0xFF01 <= cp and cp <= 0xFF0F or 0xFF1A <= cp and cp <= 0xFF20:
        return True
    if 0xFF3B <= cp and cp <= 0xFF40 or 0xFF5B <= cp and cp <= 0xFF65:
        return True
    if 0x1F300 <= cp and cp <= 0x1FAFF:
        return True  # pictographs (So)
    return False


def _flanking(s: String, pos: Int, run: Int, ch: UInt8) -> Tuple[Bool, Bool]:
    """(can_open, can_close) for a delimiter run at `pos` of length
    `run`, per the spec's left-/right-flanking definitions over
    Unicode whitespace and punctuation."""
    var before = _cp_before(s, pos)
    var after = -1
    if pos + run < s.byte_length():
        after = _decode_cp(s, pos + run)[0]
    var before_ws = before == -1 or _cp_is_space(before)
    var after_ws = after == -1 or _cp_is_space(after)
    var before_punct = before != -1 and _cp_is_punct(before)
    var after_punct = after != -1 and _cp_is_punct(after)
    var left_flanking = not after_ws and (not after_punct or before_ws or before_punct)
    var right_flanking = not before_ws and (not before_punct or after_ws or after_punct)
    if ch == 0x5F:  # underscore: intraword emphasis is not emphasis
        return (
            left_flanking and (not right_flanking or before_punct),
            right_flanking and (not left_flanking or after_punct),
        )
    return (left_flanking, right_flanking)


# ---------- inline node model ----------
#
# Inline parsing builds a list of nodes: finished HTML text and
# delimiter runs. Emphasis is resolved afterwards by the spec's
# delimiter-stack algorithm (_process_emphasis), and links splice
# their bracketed range into a single finished node — the same
# architecture as the reference implementations.


struct InNode(Copyable, Movable):
    var delim: Bool
    var html: String
    var ch: UInt8
    var num: Int
    var can_open: Bool
    var can_close: Bool

    def __init__(out self, html: String):
        self.delim = False
        self.html = html.copy()
        self.ch = 0
        self.num = 0
        self.can_open = False
        self.can_close = False

    @staticmethod
    def delimiter(ch: UInt8, num: Int, can_open: Bool, can_close: Bool) -> InNode:
        var node = InNode(String())
        node.delim = True
        node.ch = ch
        node.num = num
        node.can_open = can_open
        node.can_close = can_close
        return node^


def _render_nodes(nodes: List[InNode], lo: Int, hi: Int) -> String:
    var out = String()
    for i in range(lo, hi):
        if nodes[i].delim:
            for _ in range(nodes[i].num):
                out += String(StringSlice(unsafe_from_utf8=Span([nodes[i].ch])))
        else:
            out += nodes[i].html
    return out^


def _odd_match(opener: InNode, closer: InNode) -> Bool:
    """The rule of three: if both runs can open and close, they may
    not match when the sum of their lengths is a multiple of 3 unless
    both lengths are."""
    if opener.can_close or closer.can_open:
        if (opener.num + closer.num) % 3 == 0:
            return not (opener.num % 3 == 0 and closer.num % 3 == 0)
    return False


def _next_closer(nodes: List[InNode], bottom: Int, after: Int) -> Int:
    var i = after + 1
    if i < bottom + 1:
        i = bottom + 1
    while i < len(nodes):
        if nodes[i].delim and nodes[i].can_close and nodes[i].num > 0:
            return i
        i += 1
    return -1


def _process_emphasis(mut nodes: List[InNode], bottom: Int):
    """Match emphasis delimiters above `bottom` (a node index; -1 for
    the whole list). Matched ranges are spliced into single em/strong
    text nodes; every delimiter above the bottom leaves the stack when
    this returns, matched or not."""
    var closer = _next_closer(nodes, bottom, bottom)
    while closer != -1:
        var ch = nodes[closer].ch
        var opener = -1
        var j = closer - 1
        while j > bottom:
            if (
                nodes[j].delim
                and nodes[j].ch == ch
                and nodes[j].can_open
                and nodes[j].num > 0
                and not _odd_match(nodes[j], nodes[closer])
            ):
                opener = j
                break
            j -= 1
        if opener == -1:
            if not nodes[closer].can_open:
                var lit = String()
                for _ in range(nodes[closer].num):
                    lit += String(StringSlice(unsafe_from_utf8=Span([ch])))
                nodes[closer] = InNode(lit^)
            closer = _next_closer(nodes, bottom, closer)
            continue
        var use = 2 if nodes[opener].num >= 2 and nodes[closer].num >= 2 else 1
        var tag = String("strong") if use == 2 else String("em")
        var inner = _render_nodes(nodes, opener + 1, closer)
        nodes[opener].num -= use
        nodes[closer].num -= use
        var wrapped = "<" + tag + ">" + inner + "</" + tag + ">"
        # Splice: drop the nodes between opener and closer, insert the
        # wrapped node in their place. The closer shifts to opener + 2.
        var kept = List[InNode]()
        for i in range(0, opener + 1):
            kept.append(nodes[i].copy())
        kept.append(InNode(wrapped^))
        for i in range(closer, len(nodes)):
            kept.append(nodes[i].copy())
        nodes = kept^
        closer = opener + 2
        if nodes[closer].num == 0:
            closer = _next_closer(nodes, bottom, closer)
    # All delimiters above the bottom leave the stack as literal text.
    for i in range(bottom + 1, len(nodes)):
        if nodes[i].delim:
            var lit = String()
            for _ in range(nodes[i].num):
                lit += String(StringSlice(unsafe_from_utf8=Span([nodes[i].ch])))
            nodes[i] = InNode(lit^)


def _scan_html_comment(s: String, start: Int) -> Int:
    """Match an HTML comment at the '<' at `start`: the abrupt
    empty forms <!--> and <!--->, or <!--, text not including the
    string -->, and -->. Returns the index just past -->, or -1."""
    if s.startswith("<!-->", start):
        return start + 5
    if s.startswith("<!--->", start):
        return start + 6
    var close = s.find("-->", start + 4)
    if close == -1:
        return -1
    return close + 3


def _flush_inline(mut text: String, mut nodes: List[InNode]):
    """Append the pending literal-text buffer to the node list,
    HTML-escaped, and reset it."""
    if text.byte_length() > 0:
        nodes.append(InNode(escape_text(text)))
        text = String()


struct Bracket(Copyable, Movable):
    var node_idx: Int  # index of the '[' text node in the node list
    var src_pos: Int  # byte index of '[' in the source (of '!' for images)
    var image: Bool
    var active: Bool

    def __init__(out self, node_idx: Int, src_pos: Int, image: Bool):
        self.node_idx = node_idx
        self.src_pos = src_pos
        self.image = image
        self.active = True


def _scan_ref_label(s: String, start: Int) -> Int:
    """Scan a reference label starting just after its '[': it ends at
    the FIRST unescaped ']' and may not contain an unescaped '['
    (unlike link text, which allows balanced brackets). Returns the
    index of the ']' or -1."""
    var bytes = s.as_bytes()
    var j = start
    while j < len(bytes) and j - start < 999:
        var b = bytes[j]
        if b == 0x5C and j + 1 < len(bytes) and _is_punct(bytes[j + 1]):
            j += 2
            continue
        if b == 0x5D:
            return j
        if b == 0x5B:
            return -1
        j += 1
    return -1


def _scan_link_label(s: String, start: Int) -> Int:
    """Scan a link label starting just after its '[': returns the
    index of the ']' that closes it (balanced unescaped brackets and
    code spans are skipped), or -1. Labels are at most 999 chars."""
    var bytes = s.as_bytes()
    var n = len(bytes)
    var depth = 0
    var i = start
    while i < n and i - start <= 999:
        var b = bytes[i]
        if b == 0x5C and i + 1 < n and _is_punct(bytes[i + 1]):
            i += 2
            continue
        if b == 0x60:
            var run = 1
            var j = i + 1
            while j < n and bytes[j] == 0x60:
                run += 1
                j += 1
            var close = _find_backtick_close(s, j, run)
            i = close + run if close != -1 else j
            continue
        if b == 0x5B:
            depth += 1
        elif b == 0x5D:
            if depth == 0:
                return i
            depth -= 1
        i += 1
    return -1


def _scan_entity(s: String, start: Int) -> Tuple[Int, String]:
    """Match a character reference at the '&' at `start`.
    Returns (index just past ';', decoded text), or (-1, "")."""
    var bytes = s.as_bytes()
    var n = len(bytes)
    var i = start + 1
    if i < n and bytes[i] == 0x23:
        var j = i + 1
        var hex_mode = False
        if j < n and (bytes[j] == 0x78 or bytes[j] == 0x58):
            hex_mode = True
            j += 1
        var digits_start = j
        var cp = 0
        while j < n and bytes[j] != 0x3B:
            var d = bytes[j]
            if hex_mode:
                if _is_digit(d):
                    cp = cp * 16 + Int(d - 0x30)
                elif UInt8(0x61) <= d and d <= UInt8(0x66):
                    cp = cp * 16 + Int(d - 0x61) + 10
                elif UInt8(0x41) <= d and d <= UInt8(0x46):
                    cp = cp * 16 + Int(d - 0x41) + 10
                else:
                    return (-1, String())
            else:
                if _is_digit(d):
                    cp = cp * 10 + Int(d - 0x30)
                else:
                    return (-1, String())
            j += 1
            if j - digits_start > 8 or cp > 0x10FFFF:
                return (-1, String())
        if j >= n or j == digits_start:
            return (-1, String())
        return (j + 1, _decode_codepoint(cp))
    var j = i
    while j < n and (_is_alpha(bytes[j]) or _is_digit(bytes[j])) and j - i < 32:
        j += 1
    if j < n and bytes[j] == 0x3B and j > i:
        var val = _entity_value(_sub(s, i, j))
        if val != "":
            return (j + 1, val)
    return (-1, String())


def _close_bracket(
    s: String,
    close_pos: Int,
    mut nodes: List[InNode],
    mut brackets: List[Bracket],
    mut ctx: Ctx,
) -> Int:
    """Handle the ']' at `close_pos` against the innermost bracket.
    On success the bracketed range becomes one link/image node and
    the index just past the whole construct is returned; on failure
    -1 (the ']' is literal text and the bracket is spent)."""
    if len(brackets) == 0:
        return -1
    var b = brackets.pop()
    if not b.active:
        return -1
    var bytes = s.as_bytes()
    var n = len(bytes)
    var after = close_pos + 1
    var formed = False
    var dest = String()
    var title = String()
    var end = after
    if after < n and bytes[after] == 0x28:
        var parsed = _parse_link_dest_title(s, after)
        if parsed[0]:
            dest = parsed[1].copy()
            title = parsed[2].copy()
            end = parsed[3]
            formed = True
    var label_given = False
    if not formed and after < n and bytes[after] == 0x5B:
        var lend = _scan_ref_label(s, after + 1)
        if lend != -1:
            label_given = True
            var lab = _sub(s, after + 1, lend)
            if lab == "":
                lab = _sub(s, b.src_pos + (2 if b.image else 1), close_pos)
            var idx = ctx.refs.lookup(lab)
            if idx != -1:
                dest = ctx.refs.defs[idx].dest.copy()
                title = ctx.refs.defs[idx].title.copy()
                end = lend + 1
                formed = True
    if not formed and not label_given:
        # Shortcut (or collapsed, handled above): the bracketed text
        # itself is the label. When the inline parse failed this still
        # applies — [foo](not a link) with a [foo] definition is a
        # link followed by literal text.
        var lab2 = _sub(s, b.src_pos + (2 if b.image else 1), close_pos)
        var idx2 = ctx.refs.lookup(lab2)
        if idx2 != -1:
            dest = ctx.refs.defs[idx2].dest.copy()
            title = ctx.refs.defs[idx2].title.copy()
            end = after
            formed = True
    if not formed:
        return -1
    _process_emphasis(nodes, b.node_idx)
    var inner = _render_nodes(nodes, b.node_idx + 1, len(nodes))
    var content = _plain_text(inner) if b.image else inner
    var html = _link_html(dest, title, content, b.image)
    var kept = List[InNode]()
    for k in range(0, b.node_idx):
        kept.append(nodes[k].copy())
    kept.append(InNode(html^))
    nodes = kept^
    if not b.image:
        # A formed link deactivates every earlier link bracket.
        for k in range(len(brackets)):
            if not brackets[k].image:
                brackets[k].active = False
    return end


def render_inline(s: String, mut ctx: Ctx) -> String:
    var bytes = s.as_bytes()
    var n = len(bytes)
    var nodes = List[InNode]()
    var brackets = List[Bracket]()
    var text = String()  # pending literal text (raw, escaped on flush)

    var i = 0
    while i < n:
        var b = bytes[i]
        # Backslash escapes and backslash hard breaks.
        if b == 0x5C:
            if i + 1 < n and bytes[i + 1] == 0x0A:
                _flush_inline(text, nodes)
                nodes.append(InNode(String("<br />\n")))
                i += 2
                continue
            if i + 1 < n and bytes[i + 1] == 0x0D and i + 2 < n and bytes[i + 2] == 0x0A:
                _flush_inline(text, nodes)
                nodes.append(InNode(String("<br />\n")))
                i += 3
                continue
            if i + 1 < n and _is_punct(bytes[i + 1]):
                text += String(StringSlice(unsafe_from_utf8=bytes[i + 1 : i + 2]))
                i += 2
                continue
            text += "\\"
            i += 1
            continue
        # Code span.
        if b == 0x60:
            var run = 0
            var j = i
            while j < n and bytes[j] == 0x60:
                run += 1
                j += 1
            var close = _find_backtick_close(s, j, run)
            if close == -1:
                for _ in range(run):
                    text += "`"
                i = j
                continue
            var content = _sub(s, j, close).replace("\n", " ")
            var cb = content.as_bytes()
            if (
                len(cb) > 2
                and cb[0] == 0x20
                and cb[len(cb) - 1] == 0x20
                and String(content.strip()) != ""
            ):
                content = _sub(content, 1, len(cb) - 1)
            _flush_inline(text, nodes)
            nodes.append(InNode(String("<code>") + escape_text(content) + "</code>"))
            i = close + run
            continue
        # Inline HTML, comments and declarations, autolinks.
        if b == 0x3C:
            if s.startswith("<!--", i):
                var end = _scan_html_comment(s, i)
                if end != -1:
                    _flush_inline(text, nodes)
                    nodes.append(InNode(_sub(s, i, end)))
                    i = end
                    continue
            if s.startswith("<?", i):
                var end2 = s.find("?>", i + 2)
                if end2 != -1:
                    _flush_inline(text, nodes)
                    nodes.append(InNode(_sub(s, i, end2 + 2)))
                    i = end2 + 2
                    continue
            if s.startswith("<![CDATA[", i):
                var end3 = s.find("]]>", i + 9)
                if end3 != -1:
                    _flush_inline(text, nodes)
                    nodes.append(InNode(_sub(s, i, end3 + 3)))
                    i = end3 + 3
                    continue
            if (
                i + 2 < n
                and bytes[i + 1] == 0x21
                and UInt8(0x41) <= bytes[i + 2]
                and bytes[i + 2] <= UInt8(0x5A)
            ):
                var end4 = s.find(">", i + 2)
                if end4 != -1:
                    _flush_inline(text, nodes)
                    nodes.append(InNode(_sub(s, i, end4 + 1)))
                    i = end4 + 1
                    continue
            var auto = _scan_autolink(s, i)
            if auto[0] != -1:
                _flush_inline(text, nodes)
                if auto[2]:
                    nodes.append(InNode(_autolink_html(String("mailto:") + auto[1], auto[1])))
                else:
                    nodes.append(InNode(_autolink_html(auto[1], auto[1])))
                i = auto[0]
                continue
            var tag_end = _scan_tag(s, i)
            if tag_end != -1:
                _flush_inline(text, nodes)
                nodes.append(InNode(_sub(s, i, tag_end)))
                i = tag_end
                continue
            text += "<"
            i += 1
            continue
        # Entity / numeric character reference.
        if b == 0x26:
            var ent = _scan_entity(s, i)
            if ent[0] != -1:
                text += ent[1]
                i = ent[0]
                continue
            text += "&"
            i += 1
            continue
        # Image bracket.
        if b == 0x21 and i + 1 < n and bytes[i + 1] == 0x5B:
            _flush_inline(text, nodes)
            nodes.append(InNode(String("![")))
            brackets.append(Bracket(len(nodes) - 1, i, True))
            i += 2
            continue
        # Link bracket / footnote reference.
        if b == 0x5B:
            if i + 1 < n and bytes[i + 1] == 0x5E:
                var close = _find_bracket_close(s, i + 2)
                if close != -1:
                    var label = _sub(s, i + 2, close)
                    if ctx.refs.footnote_index(label) >= 0:
                        var num = ctx.refs.footnote_number(label)
                        _flush_inline(text, nodes)
                        nodes.append(
                            InNode(
                                String('<sup class="footnote-reference" id="fnref:')
                                + label
                                + '"><a href="#fn:'
                                + label
                                + '">'
                                + String(num)
                                + "</a></sup>"
                            )
                        )
                        i = close + 1
                        continue
            _flush_inline(text, nodes)
            nodes.append(InNode(String("[")))
            brackets.append(Bracket(len(nodes) - 1, i, False))
            i += 1
            continue
        # Close bracket.
        if b == 0x5D:
            if len(brackets) > 0:
                _flush_inline(text, nodes)
                var end = _close_bracket(s, i, nodes, brackets, ctx)
                if end != -1:
                    i = end
                    continue
            text += "]"
            i += 1
            continue
        # Emphasis delimiter run.
        if b == 0x2A or b == 0x5F:
            var run = 0
            var j = i
            while j < n and bytes[j] == b:
                run += 1
                j += 1
            var fl = _flanking(s, i, run, b)
            _flush_inline(text, nodes)
            nodes.append(InNode.delimiter(b, run, fl[0], fl[1]))
            i = j
            continue
        # Strikethrough (extension): a naive nearest-close match, as
        # before — it is not part of the CommonMark grammar.
        if b == 0x7E and i + 1 < n and bytes[i + 1] == 0x7E:
            var close = s.find("~~", i + 2)
            if close != -1 and close > i + 2:
                var content = _sub(s, i + 2, close)
                if not content.startswith(" ") and not content.endswith(" "):
                    _flush_inline(text, nodes)
                    nodes.append(
                        InNode(String("<del>") + render_inline(content, ctx) + "</del>")
                    )
                    i = close + 2
                    continue
            text += "~"
            i += 1
            continue
        # Whitespace run: before a line ending it is consumed by the
        # break — two or more spaces make a hard break; anything
        # less, tabs included, leaves a soft break (the line ending
        # itself flows on as text). Elsewhere the run is literal.
        if b == 0x20 or b == 0x09:
            var j = i
            var spaces = 0
            while j < n and (bytes[j] == 0x20 or bytes[j] == 0x09):
                if bytes[j] == 0x20:
                    spaces += 1
                j += 1
            var eol = 0
            if j < n and bytes[j] == 0x0A:
                eol = 1
            elif j + 1 < n and bytes[j] == 0x0D and bytes[j + 1] == 0x0A:
                eol = 2
            if eol > 0:
                if spaces >= 2:
                    _flush_inline(text, nodes)
                    nodes.append(InNode(String("<br />\n")))
                    i = j + eol
                else:
                    i = j
                continue
            text += _sub(s, i, j)
            i = j
            continue
        # Ordinary text.
        text += String(StringSlice(unsafe_from_utf8=bytes[i : i + 1]))
        i += 1
    _flush_inline(text, nodes)
    _process_emphasis(nodes, -1)
    return _render_nodes(nodes, 0, len(nodes))
