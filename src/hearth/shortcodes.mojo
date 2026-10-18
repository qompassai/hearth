"""Shortcodes (SPEC.md S3): `{{ name(args) }}` inline and
`{% name(args) %} body {% end %}` block forms inside Markdown bodies,
rendered through the template engine against `templates/shortcodes/`.

Expansion happens before Markdown rendering, on the raw body — with a
fenced-code guard, so a shortcode shown inside a code fence stays
literal. The block form's body is rendered as Markdown first and handed
to the template as the raw `body` value. An unregistered name is not a
shortcode and passes through untouched (it is literal text, exactly as
Zola leaves unknown `{{ ... }}` in a body alone is NOT assumed — this is
Hearth's documented rule, exercised by the corpus fixtures).
"""

from hearth.markdown import render_markdown
from hearth.templates import TemplateEnv, render_string
from hearth.value import Value

comptime MAX_SHORTCODES: Int = 10_000


def _sub(s: String, a: Int, b: Int) -> String:
    var bytes = s.as_bytes()
    var lo = a if a >= 0 else 0
    var hi = b if b <= len(bytes) else len(bytes)
    if lo >= hi:
        return String()
    return String(StringSlice(unsafe_from_utf8=bytes[lo:hi]))


def _is_ident_start(b: UInt8) -> Bool:
    return (UInt8(0x41) <= b and b <= UInt8(0x5A)) or (UInt8(0x61) <= b and b <= UInt8(0x7A)) or b == 0x5F


def _is_ident(b: UInt8) -> Bool:
    return _is_ident_start(b) or (UInt8(0x30) <= b and b <= UInt8(0x39)) or b == 0x2D


def _parse_scalar(text: String) -> Value:
    var t = String(text.strip())
    if t.byte_length() >= 2:
        var b = t.as_bytes()
        if (b[0] == 0x22 and b[t.byte_length() - 1] == 0x22) or (
            b[0] == 0x27 and b[t.byte_length() - 1] == 0x27
        ):
            return Value.string(String(t[byte=1 : t.byte_length() - 1]))
    if t == "true":
        return Value.boolean(True)
    if t == "false":
        return Value.boolean(False)
    try:
        return Value.integer(atol(t))
    except:
        pass
    return Value.string(t)


def _parse_args(src: String) raises -> Value:
    """Comma-separated `key=value` or positional arguments → a dict.
    Positional values are named arg0, arg1, ..."""
    var ctx = Value.dict(List[String](), List[Value]())
    if String(src.strip()) == "":
        return ctx^
    var parts = List[String]()
    var depth = 0
    var quote: UInt8 = 0
    var cur = String()
    var bytes = src.as_bytes()
    for i in range(len(bytes)):
        var b = bytes[i]
        if quote != 0:
            cur += String(StringSlice(unsafe_from_utf8=bytes[i : i + 1]))
            if b == quote:
                quote = 0
            continue
        if b == 0x22 or b == 0x27:
            quote = b
            cur += String(StringSlice(unsafe_from_utf8=bytes[i : i + 1]))
            continue
        if b == 0x28 or b == 0x5B:
            depth += 1
        elif b == 0x29 or b == 0x5D:
            depth -= 1
        if b == 0x2C and depth == 0:
            parts.append(cur.copy())
            cur = String()
            continue
        cur += String(StringSlice(unsafe_from_utf8=bytes[i : i + 1]))
    parts.append(cur.copy())
    var positional = 0
    for ref part in parts:
        var eq = part.find("=")
        var key = String()
        var val_text = part.copy()
        if eq != -1:
            var maybe_key = String(part[byte=:eq].strip())
            var ok = maybe_key.byte_length() > 0
            for kb in maybe_key.as_bytes():
                if not _is_ident(kb):
                    ok = False
            if ok:
                key = maybe_key^
                val_text = String(part[byte=eq + 1 :])
        if key == "":
            key = "arg" + String(positional)
            positional += 1
        ctx.set(key, _parse_scalar(val_text))
    return ctx^


struct TagParse(Copyable, Movable):
    var ok: Bool
    var name: String
    var args: Value
    var end: Int  # index just past the tag

    def __init__(out self):
        self.ok = False
        self.name = String()
        self.args = Value.dict(List[String](), List[Value]())
        self.end = 0


def _parse_tag(text: String, at: Int, closer: String) raises -> TagParse:
    """Parse `name` or `name(args)` starting at `at`, followed by `closer`
    (`}}` or `%}`). Whitespace is tolerated around the parts."""
    var result = TagParse()
    var bytes = text.as_bytes()
    var n = len(bytes)
    var i = at
    while i < n and (bytes[i] == 0x20 or bytes[i] == 0x09):
        i += 1
    if i >= n or not _is_ident_start(bytes[i]):
        return result^
    var name_start = i
    while i < n and _is_ident(bytes[i]):
        i += 1
    result.name = _sub(text, name_start, i)
    while i < n and (bytes[i] == 0x20 or bytes[i] == 0x09):
        i += 1
    var args_src = String()
    if i < n and bytes[i] == 0x28:
        var depth = 0
        var j = i
        var quote: UInt8 = 0
        while j < n:
            var b = bytes[j]
            if quote != 0:
                if b == quote:
                    quote = 0
            elif b == 0x22 or b == 0x27:
                quote = b
            elif b == 0x28:
                depth += 1
            elif b == 0x29:
                depth -= 1
                if depth == 0:
                    break
            j += 1
        if j >= n:
            return TagParse()
        args_src = _sub(text, i + 1, j)
        i = j + 1
    while i < n and (bytes[i] == 0x20 or bytes[i] == 0x09):
        i += 1
    if _sub(text, i, i + closer.byte_length()) != closer:
        return TagParse()
    result.args = _parse_args(args_src)
    result.end = i + closer.byte_length()
    result.ok = True
    return result^


def _render_shortcode(
    name: String,
    args: Value,
    body_html: String,
    has_body: Bool,
    env: TemplateEnv,
    base_url: String,
) raises -> String:
    var ctx = args.copy()
    if has_body:
        var body = Value.string(body_html)
        body.set_raw(True)
        ctx.set("body", body^)
    var source = env.get("shortcodes/" + name + ".html")
    return render_string(source, ctx, env, base_url)


def expand_shortcodes(
    body: String, env: TemplateEnv, base_url: String
) raises -> String:
    var bytes = body.as_bytes()
    var n = len(bytes)
    var out = String()
    var i = 0
    var seg = 0  # start of the pending literal segment
    var count = 0
    var in_fence = False
    var fence_char: UInt8 = 0x60
    var fence_len = 0
    var line_start = True
    while i < n:
        if line_start:
            # Fence tracking happens at line starts, before anything else.
            var j = i
            while j < n and bytes[j] == 0x20 and j - i < 4:
                j += 1
            if j < n and (bytes[j] == 0x60 or bytes[j] == 0x7E):
                var run = 0
                var k = j
                while k < n and bytes[k] == bytes[j]:
                    run += 1
                    k += 1
                if run >= 3:
                    if not in_fence:
                        in_fence = True
                        fence_char = bytes[j]
                        fence_len = run
                    elif bytes[j] == fence_char and run >= fence_len:
                        in_fence = False
            line_start = False
        if not in_fence and i + 1 < n and bytes[i] == 0x7B:
            if bytes[i + 1] == 0x7B:
                var tag = _parse_tag(body, i + 2, "}}")
                if tag.ok and env.has("shortcodes/" + tag.name + ".html"):
                    count += 1
                    if count > MAX_SHORTCODES:
                        raise Error("shortcodes: expansion bound exceeded")
                    out += _sub(body, seg, i)
                    out += _render_shortcode(
                        tag.name, tag.args, String(), False, env, base_url
                    )
                    i = tag.end
                    seg = i
                    continue
                i += 2
                continue
            if bytes[i + 1] == 0x25:
                var tag2 = _parse_tag(body, i + 2, "%}")
                if tag2.ok and env.has("shortcodes/" + tag2.name + ".html"):
                    # Find the matching {% end %}.
                    var end_marker = "{% end %}"
                    var close_at = body.find(end_marker, tag2.end)
                    if close_at == -1:
                        raise Error(
                            "shortcodes: block shortcode '"
                            + tag2.name
                            + "' has no {% end %}"
                        )
                    count += 1
                    if count > MAX_SHORTCODES:
                        raise Error("shortcodes: expansion bound exceeded")
                    var inner = _sub(body, tag2.end, close_at)
                    var inner_expanded = expand_shortcodes(inner, env, base_url)
                    var body_html = render_markdown(inner_expanded).html
                    out += _sub(body, seg, i)
                    out += _render_shortcode(
                        tag2.name, tag2.args, body_html, True, env, base_url
                    )
                    i = close_at + end_marker.byte_length()
                    seg = i
                    continue
                i += 2
                continue
        if bytes[i] == 0x0A:
            line_start = True
        i += 1
    out += _sub(body, seg, n)
    return out^
