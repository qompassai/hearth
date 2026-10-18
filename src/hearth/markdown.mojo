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
    """Percent-encode bytes a URI may not carry literally (controls, space,
    and non-ASCII), leaving the reserved/unreserved sets untouched."""
    var bytes = s.as_bytes()
    var out = String()
    comptime HEX = "0123456789ABCDEF"
    for i in range(len(bytes)):
        var b = bytes[i]
        if b >= UInt8(0x80) or b <= UInt8(0x20) or b == 0x7F:
            out += "%"
            out += String(StringSlice(unsafe_from_utf8=HEX.as_bytes()[Int(b >> 4) : Int(b >> 4) + 1]))
            out += String(StringSlice(unsafe_from_utf8=HEX.as_bytes()[Int(b & 0xF) : Int(b & 0xF) + 1]))
        else:
            out += String(StringSlice(unsafe_from_utf8=bytes[i : i + 1]))
    return out^


def normalize_label(s: String) -> String:
    var bytes = s.as_bytes()
    var out = String()
    var pending_space = False
    for i in range(len(bytes)):
        var b = bytes[i]
        if _is_space(b):
            pending_space = True
            continue
        if pending_space and out.byte_length() > 0:
            out += " "
        pending_space = False
        var lb = _lower_ascii(b)
        out += String(
            StringSlice(unsafe_from_utf8=bytes[i : i + 1])
        ) if lb == b else _sub(
            "abcdefghijklmnopqrstuvwxyz", Int(lb) - 0x61, Int(lb) - 0x61 + 1
        )
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
                col = target_col
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
                    if ok:
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
    var dest = String()
    if i < n and bytes[i] == 0x3C:  # <...>
        var j = i + 1
        var closed = False
        while j < n:
            var b = bytes[j]
            if b == 0x5C and j + 1 < n and _is_punct(bytes[j + 1]):
                j += 2
                continue
            if b == 0x3E:
                closed = True
                break
            if b == 0x3C or b == 0x0A or b == 0x0D:
                break
            j += 1
        if not closed:
            return (False, String(), String(), start)
        dest = _sub(s, i + 1, j)
        i = j + 1
    else:
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
            return (False, String(), String(), start)
        dest = _sub(s, i, j)
        i = j
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
        var q = bytes[i]
        if q != 0x22 and q != 0x27 and q != 0x28:
            return (False, String(), String(), start)
        var close: UInt8 = 0x29 if q == 0x28 else q
        var j = i + 1
        var closed = False
        while j < n:
            var b = bytes[j]
            if b == 0x5C and j + 1 < n and _is_punct(bytes[j + 1]):
                j += 2
                continue
            if q == 0x28 and b == 0x28:
                break  # unescaped '(' inside a paren title
            if b == close:
                closed = True
                break
            j += 1
        if not closed:
            return (False, String(), String(), start)
        title = _sub(s, i + 1, j)
        i = j + 1
        skipped = _skip_link_ws(s, i)
        i = skipped[0]
        if not skipped[1]:
            return (False, String(), String(), start)
    if i < n and bytes[i] == 0x29:
        return (True, dest^, title^, i + 1)
    return (False, String(), String(), start)


def _try_ref_def(line: String) -> Tuple[Bool, String, String, String]:
    """Match a link reference definition occupying a whole line:
    `[label]: dest "title"`. Returns (ok, label, dest, title)."""
    var bytes = line.as_bytes()
    var n = len(bytes)
    var i = 0
    while i < n and bytes[i] == 0x20 and i < 4:
        i += 1
    if i >= n or bytes[i] != 0x5B:
        return (False, String(), String(), String())
    var j = i + 1
    while j < n and bytes[j] != 0x5D:
        if bytes[j] == 0x5C and j + 1 < n:
            j += 1
        j += 1
    if j >= n or j + 1 >= n or bytes[j + 1] != 0x3A:
        return (False, String(), String(), String())
    var label = _sub(line, i + 1, j)
    var rest_start = j + 2
    while rest_start < n and _is_space(bytes[rest_start]):
        rest_start += 1
    var rest = _sub(line, rest_start, n)
    # Reuse the paren parser by wrapping: "(" + rest + ")".
    var wrapped = String("(") + rest + ")"
    var parsed = _parse_link_dest_title(wrapped, 0)
    if not parsed[0]:
        return (False, String(), String(), String())
    if parsed[3] != wrapped.byte_length():
        return (False, String(), String(), String())
    return (True, label^, parsed[1].copy(), parsed[2].copy())


def _collect_refs(
    lines: List[String],
) -> Tuple[RefStore, List[Bool]]:
    """Pre-pass: record link/footnote definitions and mark their lines
    consumed. A definition line inside a fenced code block is content,
    not a definition."""
    var refs = RefStore()
    var consumed = List[Bool]()
    for _ in range(len(lines)):
        consumed.append(False)
    var in_fence = False
    var fence_char: UInt8 = 0x60
    var fence_len = 0
    for idx in range(len(lines)):
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
            if run >= 3:
                if not in_fence:
                    in_fence = True
                    fence_char = bytes[pos]
                    fence_len = run
                elif bytes[pos] == fence_char and run >= fence_len:
                    in_fence = False
                continue
        if in_fence or indent >= 4:
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
                continue
        var rd = _try_ref_def(line)
        if rd[0]:
            if refs.lookup(rd[1]) == -1:
                refs.labels.append(normalize_label(rd[1]))
                refs.defs.append(RefDef(rd[2], rd[3]))
            consumed[idx] = True
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
    while i < n and bytes[i] == 0x20 and i < 4:
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
    while i < n and bytes[i] == 0x20 and i < 4:
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


def _html_block_start(line: String) -> Bool:
    var i = _first_nonspace(line)
    var bytes = line.as_bytes()
    if _leading_spaces(line) >= 4 or i + 1 >= len(bytes):
        return False
    if bytes[i] != 0x3C:
        return False
    var c = bytes[i + 1]
    if c == 0x21 or c == 0x3F:
        return True
    if c == 0x2F:
        return i + 2 < len(bytes) and _is_alpha(bytes[i + 2])
    if not _is_alpha(c):
        return False
    # Distinguish a lone autolink <scheme:...> from a tag: an autolink has
    # a ':' before any space, '=', or '>'.
    var j = i + 1
    while j < len(bytes):
        var b = bytes[j]
        if b == 0x3A:
            return False
        if b == 0x20 or b == 0x3D or b == 0x3E or b == 0x2F:
            return True
        j += 1
    return True


def _block_starts(line: String, consumed: Bool) -> Bool:
    if consumed or _is_blank(line):
        return True
    if _fence_start(line)[0] or _atx_heading(line)[0]:
        return True
    if _is_thematic_break(line) or _html_block_start(line):
        return True
    if _list_marker(line).ok:
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
        if not loose:
            # Tight list: a single-paragraph item renders without <p>.
            if inner.startswith("<p>") and inner.endswith("</p>\n") and inner.find("<p>", 3) == -1:
                inner = _sub(inner, 3, inner.byte_length() - 5) + "\n"
        if inner.startswith("<p>"):
            out += "<li>\n" + inner + "</li>\n"
        else:
            out += "<li>" + inner + "</li>\n"
    out += "</ol>\n" if first.ordered else "</ul>\n"
    return (out^, j)


def _plain_text(html: String) -> String:
    var out = String()
    var bytes = html.as_bytes()
    var i = 0
    while i < len(bytes):
        if bytes[i] == 0x3C:
            while i < len(bytes) and bytes[i] != 0x3E:
                i += 1
            i += 1
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
            var first_word = _unescape_backslash(String(info.split(" ")[0])) if info != "" else String()
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
                    inner_lines.append(stripped^)
                    j += 1
                    continue
                if _block_starts(ql, False):
                    break
                inner_lines.append(ql.copy())  # lazy continuation
                j += 1
            var no_consume = List[Bool]()
            for _ in range(len(inner_lines)):
                no_consume.append(False)
            var inner = render_blocks(
                inner_lines, 0, len(inner_lines), no_consume, ctx, depth + 1
            )
            out += "<blockquote>\n" + inner + "</blockquote>\n"
            i = j
            continue
        # HTML block: raw until a blank line.
        if _html_block_start(line):
            var j = i
            var raw = String()
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
            var pending_blanks = 0
            while j < hi:
                if _is_blank(lines[j]):
                    pending_blanks += 1
                    j += 1
                    continue
                if _leading_spaces(lines[j]) < 4:
                    break
                for _ in range(pending_blanks):
                    content += "\n"
                pending_blanks = 0
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
    """A deliberately small named-entity table: the entities the estate's
    corpora and the spec's own examples exercise. Unknown names stay
    literal text. Returns "" when the name is not in the table."""
    if name == "amp":
        return "&"
    if name == "apos":
        return "'"
    if name == "copy":
        return "©"
    if name == "dagger":
        return "†"
    if name == "deg":
        return "°"
    if name == "divide":
        return "÷"
    if name == "gt":
        return ">"
    if name == "hellip":
        return "…"
    if name == "laquo":
        return "«"
    if name == "ldquo":
        return "“"
    if name == "lsquo":
        return "‘"
    if name == "lt":
        return "<"
    if name == "mdash":
        return "—"
    if name == "micro":
        return "µ"
    if name == "middot":
        return "·"
    if name == "nbsp":
        return " "
    if name == "ndash":
        return "–"
    if name == "para":
        return "¶"
    if name == "plusmn":
        return "±"
    if name == "quot":
        return '"'
    if name == "raquo":
        return "»"
    if name == "rdquo":
        return "”"
    if name == "reg":
        return "®"
    if name == "rsquo":
        return "’"
    if name == "sect":
        return "§"
    if name == "times":
        return "×"
    if name == "trade":
        return "™"
    return String()


def _decode_codepoint(cp: Int) -> String:
    if cp == 0 or cp > 0x10FFFF or (0xD800 <= cp and cp <= 0xDFFF):
        return "�"
    var buf = List[UInt8]()
    if cp < 0x80:
        buf.append(UInt8(cp))
    elif cp < 0x800:
        buf.append(UInt8(0xC0 | (cp >> 6)))
        buf.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        buf.append(UInt8(0xE0 | (cp >> 12)))
        buf.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        buf.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        buf.append(UInt8(0xF0 | (cp >> 18)))
        buf.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        buf.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        buf.append(UInt8(0x80 | (cp & 0x3F)))
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
    """Match an HTML comment at the '<' at `start` per the spec's
    grammar: <!--, text that does not start with > or -> and contains
    no dash followed by ->, then -->. Returns the index just past
    the closing -->, or -1."""
    var bytes = s.as_bytes()
    var n = len(bytes)
    var i = start + 4
    if i >= n or bytes[i] == 0x3E or s.startswith("->", i):
        return -1
    while i < n:
        if bytes[i] == 0x2D and s.startswith("->", i + 1):
            return i + 3
        i += 1
    return -1


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
        var lend = _scan_link_label(s, after + 1)
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
        # Hard break: two or more spaces before a line ending.
        if b == 0x20:
            var j = i
            while j < n and bytes[j] == 0x20:
                j += 1
            if j < n and bytes[j] == 0x0A and j - i >= 2:
                _flush_inline(text, nodes)
                nodes.append(InNode(String("<br />\n")))
                i = j + 1
                continue
            if j + 1 < n and bytes[j] == 0x0D and bytes[j + 1] == 0x0A and j - i >= 2:
                _flush_inline(text, nodes)
                nodes.append(InNode(String("<br />\n")))
                i = j + 2
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
