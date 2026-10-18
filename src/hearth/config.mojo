"""TOML-subset parsing for Hearth config files and front matter.

Mojo has no stdlib TOML. This is a hand-rolled, bounded scanner for the
subset the estate's corpora use, enumerated here as the contract:

- comments (`#` to end of line, outside strings)
- bare keys and dotted key paths (`a.b.c = 1`), quoted keys
- `[table]` and `[a.b]` headers, `[[array-of-tables]]` headers
- values: basic strings (with escapes), literal strings, integers,
  floats, booleans, dates/times (kept as their source text),
  arrays (multi-line, trailing commas), inline tables

Anything outside the subset is a hard error naming the line — never a
silent mis-parse (SPEC.md S5). Bounds are constants: input size, table
depth, and value count are all capped.
"""

from hearth.value import Value, V_DICT, V_LIST, V_STRING

comptime MAX_INPUT_BYTES: Int = 1 << 20
comptime MAX_DEPTH: Int = 8
comptime MAX_VALUES: Int = 100_000


struct TomlParser:
    var text: String
    var pos: Int
    var line: Int
    var values: Int

    def __init__(out self, text: String):
        self.text = text.copy()
        self.pos = 0
        self.line = 1
        self.values = 0

    def error(self, msg: String) raises -> String:
        return String("toml: line ") + String(self.line) + ": " + msg

    def peek(self) -> String:
        if self.pos >= self.text.byte_length():
            return String()
        return String(
            StringSlice(
                unsafe_from_utf8=self.text.as_bytes()[self.pos : self.pos + 1]
            )
        )

    def peek_at(self, off: Int) -> String:
        var p = self.pos + off
        if p >= self.text.byte_length():
            return String()
        return String(
            StringSlice(unsafe_from_utf8=self.text.as_bytes()[p : p + 1])
        )

    def starts(self, s: String) -> Bool:
        var tb = self.text.as_bytes()
        var sb = s.as_bytes()
        if self.pos + len(sb) > len(tb):
            return False
        for j in range(len(sb)):
            if tb[self.pos + j] != sb[j]:
                return False
        return True

    def advance(mut self, n: Int = 1):
        for _ in range(n):
            if self.pos < self.text.byte_length():
                if self.text.as_bytes()[self.pos] == 0x0A:
                    self.line += 1
                self.pos += 1

    def skip_ws_comments(mut self, newlines: Bool):
        while self.pos < self.text.byte_length():
            var c = self.peek()
            if c == " " or c == "\t" or (newlines and (c == "\n" or c == "\r")):
                self.advance()
            elif c == "#":
                while self.pos < self.text.byte_length() and self.peek() != "\n":
                    self.advance()
            else:
                break

    def expect(mut self, s: String) raises:
        if not self.starts(s):
            raise Error(self.error("expected '" + s + "'"))
        self.advance(s.byte_length())

    def parse_key(mut self) raises -> String:
        self.skip_ws_comments(False)
        var c = self.peek()
        if c == '"' or c == "'":
            return self.parse_string()
        var start = self.pos
        while self.pos < self.text.byte_length():
            var b = self.text.as_bytes()[self.pos]
            var ok = (
                (b >= UInt8(0x41) and b <= UInt8(0x5A))
                or (b >= UInt8(0x61) and b <= UInt8(0x7A))
                or (b >= UInt8(0x30) and b <= UInt8(0x39))
                or b == 0x5F
                or b == 0x2D
            )
            if not ok:
                break
            self.advance()
        if self.pos == start:
            raise Error(self.error("expected a key"))
        return String(
            StringSlice(
                unsafe_from_utf8=self.text.as_bytes()[start : self.pos]
            )
        )

    def parse_keypath(mut self) raises -> List[String]:
        var path = List[String]()
        while True:
            path.append(self.parse_key())
            self.skip_ws_comments(False)
            if self.peek() == ".":
                self.advance()
            else:
                break
        return path^

    def parse_string(mut self) raises -> String:
        var quote = self.peek()
        if self.starts('"""') or self.starts("'''"):
            var triple = self.peek_at(0) + self.peek_at(1) + self.peek_at(2)
            self.advance(3)
            var start = self.pos
            if self.peek() == "\n":
                self.advance()
                start = self.pos
            while self.pos < self.text.byte_length():
                if self.starts(triple):
                    var body = String(
                        StringSlice(
                            unsafe_from_utf8=self.text.as_bytes()[start : self.pos]
                        )
                    )
                    self.advance(3)
                    if quote == '"':
                        return self._unescape(body)
                    return body^
                self.advance()
            raise Error(self.error("unterminated multiline string"))
        self.advance()
        var out = String()
        while self.pos < self.text.byte_length():
            var c = self.peek()
            if c == quote:
                self.advance()
                if quote == '"':
                    return self._unescape(out)
                return out^
            if c == "\n":
                raise Error(self.error("unterminated string"))
            out += c
            self.advance()
        raise Error(self.error("unterminated string"))

    def _unescape(self, s: String) raises -> String:
        if s.find("\\") == -1:
            return s.copy()
        var out = String()
        var i = 0
        var bytes = s.as_bytes()
        while i < len(bytes):
            var b = bytes[i]
            if b != 0x5C:
                out += String(StringSlice(unsafe_from_utf8=bytes[i : i + 1]))
                i += 1
                continue
            if i + 1 >= len(bytes):
                raise Error(self.error("dangling escape in string"))
            var e = bytes[i + 1]
            if e == 0x6E:
                out += "\n"
                i += 2
            elif e == 0x74:
                out += "\t"
                i += 2
            elif e == 0x72:
                out += "\r"
                i += 2
            elif e == 0x22:
                out += '"'
                i += 2
            elif e == 0x5C:
                out += "\\"
                i += 2
            elif e == 0x75:
                if i + 5 >= len(bytes):
                    raise Error(self.error("bad \\u escape"))
                var cp = 0
                for k in range(4):
                    cp = cp * 16 + _hex_val(bytes[i + 2 + k])
                out += _encode_utf8(cp)
                i += 6
            else:
                raise Error(self.error("unsupported escape in string"))
        return out^

    def parse_number_or_date(mut self) raises -> Value:
        var start = self.pos
        while self.pos < self.text.byte_length():
            var b = self.text.as_bytes()[self.pos]
            var ok = (
                (b >= UInt8(0x30) and b <= UInt8(0x39))
                or b == 0x2D
                or b == 0x2B
                or b == 0x2E
                or b == 0x3A
                or b == 0x5A
                or b == 0x65
                or b == 0x45
                or b == 0x5F
            )
            if not ok:
                break
            self.advance()
        var tok = String(
            StringSlice(unsafe_from_utf8=self.text.as_bytes()[start : self.pos])
        )
        # Dates and times are carried as their source text.
        if tok.find("-") != -1 and tok.find(":") == -1 and _looks_like_date(tok):
            return Value.string(tok)
        if tok.find(":") != -1:
            return Value.string(tok)
        var clean = tok.replace("_", "")
        if clean.find(".") != -1 or clean.find("e") != -1 or clean.find("E") != -1:
            try:
                return Value.floating(atof(clean))
            except:
                raise Error(self.error("bad float '" + tok + "'"))
        try:
            return Value.integer(atol(clean))
        except:
            raise Error(self.error("bad integer '" + tok + "'"))

    def parse_value(mut self, depth: Int) raises -> Value:
        if depth > MAX_DEPTH:
            raise Error(self.error("value nested too deeply"))
        self.values += 1
        if self.values > MAX_VALUES:
            raise Error(self.error("too many values"))
        self.skip_ws_comments(False)
        var c = self.peek()
        if c == '"' or c == "'":
            return Value.string(self.parse_string())
        if c == "[":
            self.advance()
            var items = List[Value]()
            while True:
                self.skip_ws_comments(True)
                if self.peek() == "]":
                    self.advance()
                    break
                items.append(self.parse_value(depth + 1))
                self.skip_ws_comments(True)
                if self.peek() == ",":
                    self.advance()
                elif self.peek() == "]":
                    self.advance()
                    break
                else:
                    raise Error(self.error("expected ',' or ']' in array"))
            return Value.list(items)
        if c == "{":
            self.advance()
            var table = Value.dict(List[String](), List[Value]())
            while True:
                self.skip_ws_comments(True)
                if self.peek() == "}":
                    self.advance()
                    break
                var path = self.parse_keypath()
                self.skip_ws_comments(False)
                self.expect("=")
                var v = self.parse_value(depth + 1)
                _dict_set_path(table, path, v^)
                self.skip_ws_comments(True)
                if self.peek() == ",":
                    self.advance()
                elif self.peek() == "}":
                    self.advance()
                    break
                else:
                    raise Error(self.error("expected ',' or '}' in inline table"))
            return table^
        if self.starts("true"):
            self.advance(4)
            return Value.boolean(True)
        if self.starts("false"):
            self.advance(5)
            return Value.boolean(False)
        return self.parse_number_or_date()


def _hex_val(b: UInt8) -> Int:
    if b >= UInt8(0x30) and b <= UInt8(0x39):
        return Int(b - 0x30)
    if b >= UInt8(0x61) and b <= UInt8(0x66):
        return Int(b - 0x61) + 10
    if b >= UInt8(0x41) and b <= UInt8(0x46):
        return Int(b - 0x41) + 10
    return 0


def _encode_utf8(cp: Int) -> String:
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


def _looks_like_date(tok: String) -> Bool:
    # YYYY-MM-DD prefix is enough for the subset.
    if tok.byte_length() < 10:
        return False
    var b = tok.as_bytes()
    return (
        b[4] == 0x2D
        and b[7] == 0x2D
        and b[0] >= 0x30
        and b[0] <= 0x39
    )


def _dict_ensure_path(mut root: Value, path: List[String]) raises:
    """Create the table at dotted `path` if it does not exist yet (so a
    header with no keyvals still yields an empty table). Descends into the
    last element of arrays of tables, mirroring _dict_set_path."""
    if root.kind() != V_DICT:
        raise Error("toml: cannot open a table inside a non-table")
    if len(path) == 1:
        if root.get(path[0]).is_none():
            root.set(path[0], Value.dict(List[String](), List[Value]()))
        return
    var head = path[0]
    var child = root.get(head)
    var rest = List[String]()
    for j in range(1, len(path)):
        rest.append(path[j].copy())
    if child.kind() == V_LIST:
        var last = child.at(child.length() - 1)
        _dict_ensure_path(last, rest)
        var items = List[Value]()
        for j in range(child.length() - 1):
            items.append(child.at(j))
        items.append(last^)
        root.set(head, Value.list(items))
        return
    if child.kind() != V_DICT:
        child = Value.dict(List[String](), List[Value]())
    _dict_ensure_path(child, rest)
    root.set(head, child^)


def _dict_set_path(mut root: Value, path: List[String], var val: Value) raises:
    """Set `val` at dotted `path` inside dict `root`, creating tables and
    descending into the last element of arrays of tables."""
    if root.kind() != V_DICT:
        raise Error("toml: cannot set a key on a non-table")
    if len(path) == 1:
        root.set(path[0], val^)
        return
    var head = path[0]
    var child = root.get(head)
    if child.kind() == V_LIST:
        if child.length() == 0:
            raise Error("toml: empty array of tables at '" + head + "'")
        var last = child.at(child.length() - 1)
        var rest = List[String]()
        for j in range(1, len(path)):
            rest.append(path[j].copy())
        _dict_set_path(last, rest, val^)
        # Replace the last element: rebuild the list.
        var items = List[Value]()
        for j in range(child.length() - 1):
            items.append(child.at(j))
        items.append(last^)
        root.set(head, Value.list(items))
        return
    if child.kind() != V_DICT:
        child = Value.dict(List[String](), List[Value]())
    var rest2 = List[String]()
    for j in range(1, len(path)):
        rest2.append(path[j].copy())
    _dict_set_path(child, rest2, val^)
    root.set(head, child^)


def _dict_append_path(mut root: Value, path: List[String]) raises:
    """Append a fresh table at dotted `path` (for [[array-of-tables]])."""
    if len(path) == 1:
        var cur = root.get(path[0])
        if cur.kind() != V_LIST:
            cur = Value.list(List[Value]())
        cur.push(Value.dict(List[String](), List[Value]()))
        root.set(path[0], cur^)
        return
    var head = path[0]
    var child = root.get(head)
    if child.kind() == V_LIST:
        var last = child.at(child.length() - 1)
        var rest = List[String]()
        for j in range(1, len(path)):
            rest.append(path[j].copy())
        _dict_append_path(last, rest)
        var items = List[Value]()
        for j in range(child.length() - 1):
            items.append(child.at(j))
        items.append(last^)
        root.set(head, Value.list(items))
        return
    if child.kind() != V_DICT:
        child = Value.dict(List[String](), List[Value]())
    var rest2 = List[String]()
    for j in range(1, len(path)):
        rest2.append(path[j].copy())
    _dict_append_path(child, rest2)
    root.set(head, child^)


def parse_toml(text: String) raises -> Value:
    """Parse the TOML subset into a dict Value. Raises on anything outside
    the subset."""
    if text.byte_length() > MAX_INPUT_BYTES:
        raise Error("toml: input exceeds size bound")
    var p = TomlParser(text)
    var root = Value.dict(List[String](), List[Value]())
    var current = List[String]()
    while True:
        p.skip_ws_comments(True)
        if p.pos >= p.text.byte_length():
            break
        if p.peek() == "[":
            var is_array = p.peek_at(1) == "["
            p.advance(2 if is_array else 1)
            current = p.parse_keypath()
            if len(current) > MAX_DEPTH:
                raise Error(p.error("table path too deep"))
            p.skip_ws_comments(False)
            if is_array:
                p.expect("]]")
                _dict_append_path(root, current)
            else:
                p.expect("]")
                _dict_ensure_path(root, current)
        else:
            var path = p.parse_keypath()
            p.skip_ws_comments(False)
            p.expect("=")
            var v = p.parse_value(0)
            var full = List[String]()
            for ref seg in current:
                full.append(seg.copy())
            for ref seg in path:
                full.append(seg.copy())
            _dict_set_path(root, full, v^)
        # End of statement: only whitespace, a comment, or a newline may
        # follow on the line (arrays/inline tables already consumed theirs).
        p.skip_ws_comments(False)
        if p.pos < p.text.byte_length() and p.peek() != "\n" and p.peek() != "\r":
            raise Error(p.error("unexpected trailing characters"))
    return root^
