"""Hearth's template engine: the SPEC.md S3 subset of Tera/Zola syntax,
implemented natively (the adoption spike for the community template
library failed on includes and inheritance — see spikes/SPIKES.md).

Supported, and only this:
- `{{ expr }}` output, HTML-escaped by default; values marked raw or
  passed through `| safe` render verbatim
- expressions: dotted/indexed lookup, literals, `not/and/or`, comparisons,
  `in`, arithmetic `+ - * / %`, string concatenation `~`
- filters: default (alias d), escape (e), first, int, join, last, length,
  lower, replace, reverse, safe, slugify, sort, string, title, trim,
  upper
- `{% if %}/{% elif %}/{% else %}`, `{% for x in expr %}` with
  loop.index/index0/first/last/length and an optional `{% else %}`,
  `{% set name = expr %}`, `{% include "name" %}`,
  `{% extends "name" %}` with `{% block name %}` (one level)
- the `get_url(path=..., trailing_slash=...)` builtin (Zola-compatible)
- `{# comments #}`, and `-` whitespace control on any tag

A name that does not resolve reads as none (falsy, prints empty) rather
than raising: the kintsugi corpus relies on testing optional front
matter fields (e.g. an author link that may be an empty string or
absent). Everything else outside the subset is a hard error.
"""

from hearth.markdown import slugify
from hearth.value import (
    Value,
    V_BOOL,
    V_DICT,
    V_FLOAT,
    V_INT,
    V_LIST,
    V_NONE,
    V_STRING,
)

comptime MAX_TEMPLATE_BYTES: Int = 1 << 20
comptime MAX_NODES: Int = 100_000
comptime MAX_INCLUDE_DEPTH: Int = 16
comptime MAX_LOOP_ITEMS: Int = 1_000_000

comptime N_TEXT: Int = 0
comptime N_OUTPUT: Int = 1
comptime N_IF: Int = 2
comptime N_FOR: Int = 3
comptime N_SET: Int = 4
comptime N_INCLUDE: Int = 5
comptime N_EXTENDS: Int = 6
comptime N_BLOCK: Int = 7
comptime N_LIST: Int = 8
comptime N_BRANCH: Int = 9


def escape_html(s: String) -> String:
    var bytes = s.as_bytes()
    var out = String()
    var run = 0
    for i in range(len(bytes)):
        var b = bytes[i]
        var rep = String()
        if b == 0x26:
            rep = "&amp;"
        elif b == 0x3C:
            rep = "&lt;"
        elif b == 0x3E:
            rep = "&gt;"
        elif b == 0x22:
            rep = "&quot;"
        elif b == 0x27:
            rep = "&#x27;"
        else:
            continue
        if i > run:
            out += String(StringSlice(unsafe_from_utf8=bytes[run:i]))
        out += rep
        run = i + 1
    out += String(StringSlice(unsafe_from_utf8=bytes[run:]))
    return out^


struct TemplateEnv(Copyable, Movable):
    var names: List[String]
    var sources: List[String]
    var docs: List[Doc]
    var doc_valid: List[Bool]

    def __init__(out self):
        self.names = _stops("")
        self.sources = _stops("")
        self.docs = List[Doc]()
        self.doc_valid = List[Bool]()

    def add(mut self, name: String, source: String):
        for i in range(len(self.names)):
            if self.names[i] == name:
                self.sources[i] = source.copy()
                self.doc_valid[i] = False
                return
        self.names.append(name.copy())
        self.sources.append(source.copy())
        self.docs.append(Doc())
        self.doc_valid.append(False)

    def get(self, name: String) raises -> String:
        for i in range(len(self.names)):
            if self.names[i] == name:
                return self.sources[i].copy()
        raise Error("template not found: " + name)

    def has(self, name: String) -> Bool:
        for ref n in self.names:
            if n == name:
                return True
        return False

    def parsed(mut self, name: String) raises -> Doc:
        """The named template parsed, cached across renders (a build
        renders the page template once per page; parsing must not be
        per-render work). Returns a copy: the extends path rewires the
        doc it renders, and that must not poison the cache."""
        for i in range(len(self.names)):
            if self.names[i] == name:
                if not self.doc_valid[i]:
                    self.docs[i] = parse_template(self.sources[i].copy())
                    self.doc_valid[i] = True
                return self.docs[i].copy()
        raise Error("template not found: " + name)


struct TNode(Copyable, Movable):
    var kind: Int
    var text: String
    var aux: String
    var children: List[Int]

    def __init__(out self, kind: Int, text: String, aux: String):
        self.kind = kind
        self.text = text.copy()
        self.aux = aux.copy()
        self.children = List[Int]()


struct Doc(Copyable, Movable):
    var nodes: List[TNode]
    var root: Int

    def __init__(out self):
        self.nodes = List[TNode]()
        self.root = 0

    def add(mut self, var node: TNode) -> Int:
        self.nodes.append(node^)
        return len(self.nodes) - 1


struct Token(Copyable, Movable):
    var kind: Int  # 0 text, 1 output, 2 statement
    var text: String

    def __init__(out self, kind: Int, text: String):
        self.kind = kind
        self.text = text.copy()


def _tokenize(source: String) raises -> List[Token]:
    if source.byte_length() > MAX_TEMPLATE_BYTES:
        raise Error("template exceeds size bound")
    var tokens = List[Token]()
    var bytes = source.as_bytes()
    var n = len(bytes)
    var i = 0
    var trim_next_left = False
    while i < n:
        # Find the next tag opener.
        var open_at = -1
        var kind = 0
        var j = i
        while j + 1 < n:
            if bytes[j] == 0x7B and bytes[j + 1] == 0x7B:
                open_at = j
                kind = 1
                break
            if bytes[j] == 0x7B and bytes[j + 1] == 0x25:
                open_at = j
                kind = 2
                break
            if bytes[j] == 0x7B and bytes[j + 1] == 0x23:
                open_at = j
                kind = 3
                break
            j += 1
        if open_at == -1:
            var text = String(source[byte=i:n])
            if trim_next_left:
                var lt = String(text.lstrip())
                text = lt^
            if text != "":
                tokens.append(Token(0, text))
            break
        var text2 = String(source[byte=i:open_at])
        var p = open_at + 2
        var trim_left = False
        if p < n and bytes[p] == 0x2D:
            trim_left = True
            p += 1
        if trim_next_left:
            var lt2 = String(text2.lstrip())
            text2 = lt2^
            trim_next_left = False
        if trim_left:
            var rt2 = String(text2.rstrip())
            text2 = rt2^
        if text2 != "":
            tokens.append(Token(0, text2))
        var closer0: UInt8 = 0x7D if kind == 1 else 0x25
        if kind == 3:
            closer0 = 0x23
        var close_at = -1
        var k = p
        while k + 1 < n:
            if bytes[k] == closer0 and bytes[k + 1] == 0x7D:
                close_at = k
                break
            k += 1
        if close_at == -1:
            raise Error("template: unclosed tag")
        var inner_end = close_at
        var trim_right = False
        if close_at > p and bytes[close_at - 1] == 0x2D:
            trim_right = True
            inner_end = close_at - 1
        var inner = String(
            StringSlice(unsafe_from_utf8=bytes[p:inner_end]).strip()
        )
        if kind != 3:
            tokens.append(Token(kind, inner))
        trim_next_left = trim_right
        i = close_at + 2
    return tokens^


def _stmt_word(stmt: String) -> String:
    var s = String(stmt.strip())
    var sp = s.find(" ")
    if sp == -1:
        return s^
    return String(s[byte=:sp])


def _stmt_rest(stmt: String) -> String:
    var s = String(stmt.strip())
    var sp = s.find(" ")
    if sp == -1:
        return String()
    return String(s[byte=sp + 1 :].strip())



def _stops(spec: String) -> List[String]:
    """Stop-word list from a space-separated spec (List's variadic
    constructor does not accept string literals on this pin)."""
    var out = List[String]()
    if spec == "":
        return out^
    for ref w in spec.split(" "):
        out.append(String(w))
    return out^


def _parse_nodes(
    tokens: List[Token], mut pos: Int, mut doc: Doc, stops: List[String]
) raises -> Int:
    """Parse tokens into a LIST node; stops (without consuming) when a
    statement whose first word is in `stops` is reached."""
    var list_node = doc.add(TNode(N_LIST, String(), String()))
    while pos < len(tokens):
        ref tok = tokens[pos]
        if tok.kind == 0:
            var idx = doc.add(TNode(N_TEXT, tok.text, String()))
            doc.nodes[list_node].children.append(idx)
            pos += 1
            continue
        if tok.kind == 1:
            var idx2 = doc.add(TNode(N_OUTPUT, tok.text, String()))
            doc.nodes[list_node].children.append(idx2)
            pos += 1
            continue
        var word = _stmt_word(tok.text)
        for ref stop in stops:
            if word == stop:
                return list_node
        if word == "if":
            pos += 1
            var if_node = doc.add(TNode(N_IF, String(), String()))
            var cond = _stmt_rest(tok.text)
            while True:
                var branch = doc.add(TNode(N_BRANCH, cond, String()))
                doc.nodes[if_node].children.append(branch)
                var body = _parse_nodes(
                    tokens, pos, doc, _stops("elif else endif")
                )
                doc.nodes[branch].children.append(body)
                if pos >= len(tokens):
                    raise Error("template: if without endif")
                var w2 = _stmt_word(tokens[pos].text)
                if w2 == "elif":
                    cond = _stmt_rest(tokens[pos].text)
                    pos += 1
                    continue
                if w2 == "else":
                    cond = String()
                    pos += 1
                    var ebranch = doc.add(TNode(N_BRANCH, String(), String()))
                    doc.nodes[if_node].children.append(ebranch)
                    var ebody = _parse_nodes(
                        tokens, pos, doc, _stops("endif")
                    )
                    doc.nodes[ebranch].children.append(ebody)
                    if pos >= len(tokens):
                        raise Error("template: if without endif")
                    pos += 1  # consume endif
                    break
                pos += 1  # consume endif
                break
            doc.nodes[list_node].children.append(if_node)
            continue
        if word == "for":
            var rest = _stmt_rest(tok.text)
            var in_at = rest.find(" in ")
            if in_at == -1:
                raise Error("template: for requires 'name in expr'")
            var var_name = String(rest[byte=:in_at].strip())
            var iter_expr = String(rest[byte=in_at + 4 :].strip())
            pos += 1
            var for_node = doc.add(TNode(N_FOR, var_name, iter_expr))
            var body2 = _parse_nodes(
                tokens, pos, doc, _stops("else endfor")
            )
            doc.nodes[for_node].children.append(body2)
            if pos >= len(tokens):
                raise Error("template: for without endfor")
            if _stmt_word(tokens[pos].text) == "else":
                pos += 1
                var ebody2 = _parse_nodes(
                    tokens, pos, doc, _stops("endfor")
                )
                doc.nodes[for_node].children.append(ebody2)
                if pos >= len(tokens):
                    raise Error("template: for without endfor")
            pos += 1  # consume endfor
            doc.nodes[list_node].children.append(for_node)
            continue
        if word == "set":
            var rest2 = _stmt_rest(tok.text)
            var eq = rest2.find("=")
            if eq == -1:
                raise Error("template: set requires '='")
            var idx3 = doc.add(
                TNode(
                    N_SET,
                    String(rest2[byte=:eq].strip()),
                    String(rest2[byte=eq + 1 :].strip()),
                )
            )
            doc.nodes[list_node].children.append(idx3)
            pos += 1
            continue
        if word == "include":
            var idx4 = doc.add(
                TNode(N_INCLUDE, _unquote(_stmt_rest(tok.text)), String())
            )
            doc.nodes[list_node].children.append(idx4)
            pos += 1
            continue
        if word == "extends":
            var idx5 = doc.add(
                TNode(N_EXTENDS, _unquote(_stmt_rest(tok.text)), String())
            )
            doc.nodes[list_node].children.append(idx5)
            pos += 1
            continue
        if word == "block":
            var name = _stmt_rest(tok.text)
            pos += 1
            var block_node = doc.add(TNode(N_BLOCK, name, String()))
            var body3 = _parse_nodes(
                tokens, pos, doc, _stops("endblock")
            )
            doc.nodes[block_node].children.append(body3)
            if pos >= len(tokens):
                raise Error("template: block without endblock")
            pos += 1
            doc.nodes[list_node].children.append(block_node)
            continue
        raise Error("template: unsupported statement '" + word + "'")
    return list_node


def _unquote(s: String) raises -> String:
    var t = String(s.strip())
    if t.byte_length() >= 2:
        var b = t.as_bytes()
        if (b[0] == 0x22 and b[t.byte_length() - 1] == 0x22) or (
            b[0] == 0x27 and b[t.byte_length() - 1] == 0x27
        ):
            return String(t[byte=1 : t.byte_length() - 1])
    raise Error("template: expected a quoted name, got '" + t + "'")


def parse_template(source: String) raises -> Doc:
    var tokens = _tokenize(source)
    var doc = Doc()
    var pos = 0
    doc.root = _parse_nodes(tokens, pos, doc, _stops(""))
    if len(doc.nodes) > MAX_NODES:
        raise Error("template exceeds node bound")
    return doc^


# ---------- expressions ----------

comptime E_IDENT: Int = 0
comptime E_STR: Int = 1
comptime E_INT: Int = 2
comptime E_FLOAT: Int = 3
comptime E_OP: Int = 4


struct ETok(Copyable, Movable):
    var kind: Int
    var text: String

    def __init__(out self, kind: Int, text: String):
        self.kind = kind
        self.text = text.copy()


def _lex_expr(src: String) raises -> List[ETok]:
    var toks = List[ETok]()
    var bytes = src.as_bytes()
    var n = len(bytes)
    var i = 0
    while i < n:
        var b = bytes[i]
        if b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D:
            i += 1
            continue
        if b == 0x22 or b == 0x27:
            var j = i + 1
            var out = String()
            while j < n and bytes[j] != b:
                if bytes[j] == 0x5C and j + 1 < n and b == 0x22:
                    var e = bytes[j + 1]
                    if e == 0x6E:
                        out += "\n"
                    elif e == 0x74:
                        out += "\t"
                    elif e == 0x22:
                        out += '"'
                    elif e == 0x5C:
                        out += "\\"
                    else:
                        out += String(
                            StringSlice(unsafe_from_utf8=bytes[j + 1 : j + 2])
                        )
                    j += 2
                    continue
                out += String(StringSlice(unsafe_from_utf8=bytes[j : j + 1]))
                j += 1
            if j >= n:
                raise Error("template expr: unterminated string")
            toks.append(ETok(E_STR, out))
            i = j + 1
            continue
        if (UInt8(0x30) <= b and b <= UInt8(0x39)) or (
            b == 0x2E and i + 1 < n and UInt8(0x30) <= bytes[i + 1] and bytes[i + 1] <= UInt8(0x39)
        ):
            var j = i
            var is_float = False
            while j < n and (
                (UInt8(0x30) <= bytes[j] and bytes[j] <= UInt8(0x39)) or bytes[j] == 0x2E
            ):
                if bytes[j] == 0x2E:
                    is_float = True
                j += 1
            toks.append(ETok(E_FLOAT if is_float else E_INT, String(StringSlice(unsafe_from_utf8=bytes[i:j]))))
            i = j
            continue
        if (UInt8(0x41) <= b and b <= UInt8(0x5A)) or (UInt8(0x61) <= b and b <= UInt8(0x7A)) or b == 0x5F:
            var j = i
            while j < n and (
                (UInt8(0x41) <= bytes[j] and bytes[j] <= UInt8(0x5A))
                or (UInt8(0x61) <= bytes[j] and bytes[j] <= UInt8(0x7A))
                or (UInt8(0x30) <= bytes[j] and bytes[j] <= UInt8(0x39))
                or bytes[j] == 0x5F
            ):
                j += 1
            toks.append(ETok(E_IDENT, String(StringSlice(unsafe_from_utf8=bytes[i:j]))))
            i = j
            continue
        # Operators and punctuation.
        if i + 1 < n:
            var two = String(StringSlice(unsafe_from_utf8=bytes[i : i + 2]))
            if two == "==" or two == "!=" or two == "<=" or two == ">=":
                toks.append(ETok(E_OP, two))
                i += 2
                continue
        toks.append(ETok(E_OP, String(StringSlice(unsafe_from_utf8=bytes[i : i + 1]))))
        i += 1
    return toks^


struct Evaluator:
    # The context and scopes are threaded through the parse methods as
    # borrowed parameters, never stored: storing them would deep-copy
    # the whole site context (an arena) for every expression evaluated.
    var toks: List[ETok]
    var pos: Int
    var base_url: String

    def __init__(out self, toks: List[ETok], base_url: String):
        self.toks = toks.copy()
        self.pos = 0
        self.base_url = base_url.copy()

    def peek(self) -> String:
        if self.pos < len(self.toks):
            return self.toks[self.pos].text.copy()
        return String()

    def peek_kind(self) -> Int:
        if self.pos < len(self.toks):
            return self.toks[self.pos].kind
        return -1

    def next(mut self) -> ETok:
        var t = self.toks[self.pos].copy()
        self.pos += 1
        return t^

    def expect_op(mut self, op: String) raises:
        if self.pos >= len(self.toks) or self.toks[self.pos].text != op:
            raise Error("template expr: expected '" + op + "'")
        self.pos += 1

    def lookup(self, ctx: Value, scopes: List[Value], name: String) -> Value:
        for si in range(len(scopes) - 1, -1, -1):
            var v = scopes[si].get(name)
            if not v.is_none():
                return v^
        return ctx.get(name)

    def parse_expr(mut self, ctx: Value, scopes: List[Value]) raises -> Value:
        return self.parse_or(ctx, scopes)

    def parse_or(mut self, ctx: Value, scopes: List[Value]) raises -> Value:
        var lhs = self.parse_and(ctx, scopes)
        while self.peek() == "or" and self.peek_kind() == E_IDENT:
            _ = self.next()
            var rhs = self.parse_and(ctx, scopes)
            lhs = Value.boolean(lhs.truthy() or rhs.truthy())
        return lhs^

    def parse_and(mut self, ctx: Value, scopes: List[Value]) raises -> Value:
        var lhs = self.parse_not(ctx, scopes)
        while self.peek() == "and" and self.peek_kind() == E_IDENT:
            _ = self.next()
            var rhs = self.parse_not(ctx, scopes)
            lhs = Value.boolean(lhs.truthy() and rhs.truthy())
        return lhs^

    def parse_not(mut self, ctx: Value, scopes: List[Value]) raises -> Value:
        if self.peek() == "not" and self.peek_kind() == E_IDENT:
            # `not in` is a comparison; a leading `not` here is unary when
            # the following token is not part of a comparison — handled by
            # looking at what unary-not means: it negates the comparison
            # that follows, matching Python/Tera closely enough.
            _ = self.next()
            var v = self.parse_not(ctx, scopes)
            return Value.boolean(not v.truthy())
        return self.parse_cmp(ctx, scopes)

    def parse_cmp(mut self, ctx: Value, scopes: List[Value]) raises -> Value:
        var lhs = self.parse_add(ctx, scopes)
        var op = self.peek()
        var negated = False
        if op == "not" and self.pos + 1 < len(self.toks) and self.toks[self.pos + 1].text == "in":
            _ = self.next()
            _ = self.next()
            op = "in"
            negated = True
        if op == "in" and self.peek_kind() == E_IDENT:
            _ = self.next()
            var rhs = self.parse_add(ctx, scopes)
            var result = _contains(rhs, lhs)
            return Value.boolean(not result if negated else result)
        if self.peek_kind() == E_OP and (
            op == "==" or op == "!=" or op == "<" or op == "<=" or op == ">" or op == ">="
        ):
            _ = self.next()
            var rhs2 = self.parse_add(ctx, scopes)
            return Value.boolean(_compare(lhs, rhs2, op))
        return lhs^

    def parse_add(mut self, ctx: Value, scopes: List[Value]) raises -> Value:
        var lhs = self.parse_mul(ctx, scopes)
        while self.peek_kind() == E_OP and (
            self.peek() == "+" or self.peek() == "-" or self.peek() == "~"
        ):
            var op = self.next().text
            var rhs = self.parse_mul(ctx, scopes)
            lhs = _arith(lhs, rhs, op)
        return lhs^

    def parse_mul(mut self, ctx: Value, scopes: List[Value]) raises -> Value:
        var lhs = self.parse_unary(ctx, scopes)
        while self.peek_kind() == E_OP and (
            self.peek() == "*" or self.peek() == "/" or self.peek() == "%"
        ):
            var op = self.next().text
            var rhs = self.parse_unary(ctx, scopes)
            lhs = _arith(lhs, rhs, op)
        return lhs^

    def parse_unary(mut self, ctx: Value, scopes: List[Value]) raises -> Value:
        if self.peek() == "-" and self.peek_kind() == E_OP:
            _ = self.next()
            var v = self.parse_unary(ctx, scopes)
            if v.kind() == V_INT:
                return Value.integer(-v.as_int())
            if v.kind() == V_FLOAT:
                return Value.floating(-v.as_float())
            raise Error("template expr: unary '-' on a non-number")
        return self.parse_postfix(ctx, scopes)

    def parse_postfix(mut self, ctx: Value, scopes: List[Value]) raises -> Value:
        var v = self.parse_primary(ctx, scopes)
        while True:
            if self.peek() == "." and self.peek_kind() == E_OP:
                _ = self.next()
                if self.pos >= len(self.toks) or self.toks[self.pos].kind != E_IDENT:
                    raise Error("template expr: expected a name after '.'")
                var name = self.next().text
                v = v.get(name)
                continue
            if self.peek() == "[" and self.peek_kind() == E_OP:
                _ = self.next()
                var key = self.parse_expr(ctx, scopes)
                self.expect_op("]")
                if key.kind() == V_INT:
                    v = v.at(key.as_int())
                else:
                    v = v.get(key.to_display())
                continue
            if self.peek() == "|" and self.peek_kind() == E_OP:
                _ = self.next()
                if self.pos >= len(self.toks) or self.toks[self.pos].kind != E_IDENT:
                    raise Error("template expr: expected a filter name after '|'")
                var fname = self.next().text
                var args = List[Value]()
                var kwargs = Value.dict(_stops(""), List[Value]())
                if self.peek() == "(" and self.peek_kind() == E_OP:
                    _ = self.next()
                    self.parse_args(ctx, scopes, args, kwargs)
                v = _apply_filter(fname, v^, args, kwargs)
                continue
            break
        return v^

    def parse_args(
        mut self,
        ctx: Value,
        scopes: List[Value],
        mut args: List[Value],
        mut kwargs: Value,
    ) raises:
        if self.peek() == ")" and self.peek_kind() == E_OP:
            _ = self.next()
            return
        while True:
            if (
                self.peek_kind() == E_IDENT
                and self.pos + 1 < len(self.toks)
                and self.toks[self.pos + 1].text == "="
                and self.toks[self.pos + 1].kind == E_OP
            ):
                var key = self.next().text
                _ = self.next()
                kwargs.set(key, self.parse_expr(ctx, scopes))
            else:
                args.append(self.parse_expr(ctx, scopes))
            if self.peek() == "," and self.peek_kind() == E_OP:
                _ = self.next()
                continue
            break
        self.expect_op(")")

    def parse_primary(mut self, ctx: Value, scopes: List[Value]) raises -> Value:
        if self.pos >= len(self.toks):
            raise Error("template expr: unexpected end of expression")
        var tok = self.toks[self.pos].copy()
        if tok.kind == E_STR:
            _ = self.next()
            return Value.string(tok.text)
        if tok.kind == E_INT:
            _ = self.next()
            return Value.integer(atol(tok.text))
        if tok.kind == E_FLOAT:
            _ = self.next()
            return Value.floating(atof(tok.text))
        if tok.kind == E_OP and tok.text == "(":
            _ = self.next()
            var v = self.parse_expr(ctx, scopes)
            self.expect_op(")")
            return v^
        if tok.kind == E_OP and tok.text == "[":
            _ = self.next()
            var items = List[Value]()
            if not (self.peek() == "]" and self.peek_kind() == E_OP):
                while True:
                    items.append(self.parse_expr(ctx, scopes))
                    if self.peek() == "," and self.peek_kind() == E_OP:
                        _ = self.next()
                        continue
                    break
            self.expect_op("]")
            return Value.list(items)
        if tok.kind == E_IDENT:
            if tok.text == "true":
                _ = self.next()
                return Value.boolean(True)
            if tok.text == "false":
                _ = self.next()
                return Value.boolean(False)
            if tok.text == "none":
                _ = self.next()
                return Value.none()
            _ = self.next()
            if self.peek() == "(" and self.peek_kind() == E_OP:
                _ = self.next()
                var args = List[Value]()
                var kwargs = Value.dict(_stops(""), List[Value]())
                self.parse_args(ctx, scopes, args, kwargs)
                return self.call_builtin(tok.text, args, kwargs)
            return self.lookup(ctx, scopes, tok.text)
        raise Error("template expr: unexpected token '" + tok.text + "'")

    def call_builtin(
        self, name: String, args: List[Value], kwargs: Value
    ) raises -> Value:
        if name == "get_url":
            var path = String()
            var p = kwargs.get("path")
            if not p.is_none():
                path = p.to_display()
            elif len(args) > 0:
                path = args[0].to_display()
            else:
                raise Error("get_url: a path argument is required")
            if path.startswith("@/"):
                var tail = String(path[byte=2:])
                path = tail^
            var trailing = kwargs.get("trailing_slash")
            var url = _join_url(self.base_url, path)
            if not trailing.is_none() and trailing.truthy():
                if not url.endswith("/"):
                    url += "/"
            var v = Value.string(url)
            v.set_raw(True)
            return v^
        if name == "range":
            if len(args) < 1:
                raise Error("range: an end argument is required")
            var start = 0
            var end = args[0].as_int()
            if len(args) > 1:
                start = args[0].as_int()
                end = args[1].as_int()
            var items = List[Value]()
            var k = start
            while k < end:
                items.append(Value.integer(k))
                k += 1
            return Value.list(items)
        raise Error("template: unknown function '" + name + "'")


def _join_url(base: String, path: String) -> String:
    var b = base.copy()
    while b.endswith("/") and b.byte_length() > 1:
        var tail = String(b[byte=: b.byte_length() - 1])
        b = tail^
    var p = path.copy()
    while p.startswith("/"):
        var tail2 = String(p[byte=1:])
        p = tail2^
    if b == "" or b == "/":
        return "/" + p
    return b + "/" + p


def _contains(haystack: Value, needle: Value) -> Bool:
    if haystack.kind() == V_LIST:
        var n = haystack.length()
        for i in range(n):
            if haystack.at(i).equals(needle):
                return True
        return False
    if haystack.kind() == V_STRING:
        return haystack.as_string().find(needle.to_display()) != -1
    if haystack.kind() == V_DICT:
        return haystack.has(needle.to_display())
    return False


def _compare(lhs: Value, rhs: Value, op: String) -> Bool:
    var lk = lhs.kind()
    var rk = rhs.kind()
    var numeric = (lk == V_INT or lk == V_FLOAT) and (rk == V_INT or rk == V_FLOAT)
    if numeric:
        var a = lhs.as_float()
        var b = rhs.as_float()
        if op == "==":
            return a == b
        if op == "!=":
            return a != b
        if op == "<":
            return a < b
        if op == "<=":
            return a <= b
        if op == ">":
            return a > b
        return a >= b
    if lk == V_STRING and rk == V_STRING:
        var a2 = lhs.as_string()
        var b2 = rhs.as_string()
        if op == "==":
            return a2 == b2
        if op == "!=":
            return a2 != b2
        if op == "<":
            return a2 < b2
        if op == "<=":
            return a2 <= b2
        if op == ">":
            return a2 > b2
        return a2 >= b2
    if op == "==":
        return lhs.equals(rhs)
    if op == "!=":
        return not lhs.equals(rhs)
    return False


def _arith(lhs: Value, rhs: Value, op: String) raises -> Value:
    if op == "~":
        return Value.string(lhs.to_display() + rhs.to_display())
    var lk = lhs.kind()
    var rk = rhs.kind()
    if lk == V_STRING and op == "+" :
        return Value.string(lhs.as_string() + rhs.to_display())
    if not ((lk == V_INT or lk == V_FLOAT) and (rk == V_INT or rk == V_FLOAT)):
        raise Error("template expr: arithmetic on non-numbers")
    if lk == V_INT and rk == V_INT and op != "/":
        var a = lhs.as_int()
        var b = rhs.as_int()
        if op == "+":
            return Value.integer(a + b)
        if op == "-":
            return Value.integer(a - b)
        if op == "*":
            return Value.integer(a * b)
        if b == 0:
            raise Error("template expr: modulo by zero")
        return Value.integer(a % b)
    var x = lhs.as_float()
    var y = rhs.as_float()
    if op == "+":
        return Value.floating(x + y)
    if op == "-":
        return Value.floating(x - y)
    if op == "*":
        return Value.floating(x * y)
    if op == "/":
        if y == 0.0:
            raise Error("template expr: division by zero")
        return Value.floating(x / y)
    raise Error("template expr: unsupported operator '" + op + "'")


def _apply_filter(
    name: String, var value: Value, args: List[Value], kwargs: Value
) raises -> Value:
    if name == "safe":
        value.set_raw(True)
        return value^
    if name == "escape" or name == "e":
        value.set_raw(False)
        if value.kind() != V_STRING:
            return Value.string(value.to_display())
        return value^
    if name == "default" or name == "d":
        if value.is_none():
            if len(args) > 0:
                return args[0].copy()
            return Value.string(kwargs.get("value").to_display()) if not kwargs.get("value").is_none() else Value.none()
        return value^
    if name == "length":
        if value.kind() == V_STRING:
            return Value.integer(value.as_string().byte_length())
        if value.kind() == V_LIST or value.kind() == V_DICT:
            return Value.integer(value.length())
        if value.is_none():
            return Value.integer(0)
        raise Error("filter length: unsupported value kind")
    if name == "join":
        var sep = String()
        if len(args) > 0:
            sep = args[0].to_display()
        elif not kwargs.get("sep").is_none():
            sep = kwargs.get("sep").to_display()
        if value.kind() != V_LIST:
            raise Error("filter join: value is not a list")
        var parts = _stops("")
        for i in range(value.length()):
            parts.append(value.at(i).to_display())
        return Value.string(sep.join(parts))
    if name == "upper":
        return Value.string(value.to_display().upper())
    if name == "lower":
        return Value.string(value.to_display().lower())
    if name == "title":
        var words = value.to_display().split(" ")
        var out = _stops("")
        for ref w in words:
            if w.byte_length() == 0:
                out.append(String())
            else:
                out.append(String(String(w[byte=:1]).upper() + String(w[byte=1:]).lower()))
        return Value.string(" ".join(out))
    if name == "trim":
        return Value.string(String(value.to_display().strip()))
    if name == "first":
        if value.kind() == V_LIST:
            return value.at(0) if value.length() > 0 else Value.none()
        if value.kind() == V_STRING and value.as_string().byte_length() > 0:
            return Value.string(String(value.as_string()[byte=:1]))
        return Value.none()
    if name == "last":
        if value.kind() == V_LIST:
            return value.at(value.length() - 1) if value.length() > 0 else Value.none()
        if value.kind() == V_STRING and value.as_string().byte_length() > 0:
            var s = value.as_string()
            return Value.string(String(s[byte=s.byte_length() - 1 :]))
        return Value.none()
    if name == "reverse":
        if value.kind() == V_LIST:
            var items = List[Value]()
            for i in range(value.length() - 1, -1, -1):
                items.append(value.at(i))
            return Value.list(items)
        return value^
    if name == "sort":
        if value.kind() != V_LIST:
            raise Error("filter sort: value is not a list")
        var items = List[Value]()
        for i in range(value.length()):
            items.append(value.at(i))
        # Insertion sort; keys are strings unless every item is numeric.
        var all_num = True
        for ref it in items:
            if it.kind() != V_INT and it.kind() != V_FLOAT:
                all_num = False
        for i in range(1, len(items)):
            var j = i
            while j > 0:
                var a = items[j - 1].copy()
                var b = items[j].copy()
                var less: Bool
                if all_num:
                    less = b.as_float() < a.as_float()
                else:
                    less = b.to_display() < a.to_display()
                if not less:
                    break
                items[j - 1] = b^
                items[j] = a^
                j -= 1
        return Value.list(items)
    if name == "replace":
        if len(args) < 2:
            raise Error("filter replace: needs from and to arguments")
        return Value.string(
            value.to_display().replace(args[0].to_display(), args[1].to_display())
        )
    if name == "int":
        if value.kind() == V_FLOAT:
            return Value.integer(Int(value.as_float()))
        if value.kind() == V_INT:
            return value^
        try:
            return Value.integer(atol(value.to_display()))
        except:
            return Value.integer(0)
    if name == "float":
        if value.kind() == V_INT:
            return Value.floating(Float64(value.as_int()))
        if value.kind() == V_FLOAT:
            return value^
        return Value.floating(atof(value.to_display()))
    if name == "string":
        return Value.string(value.to_display())
    if name == "slugify":
        return Value.string(slugify(value.to_display()))
    raise Error("template: unknown filter '" + name + "'")


def eval_expr(
    src: String, ctx: Value, scopes: List[Value], base_url: String
) raises -> Value:
    var toks = _lex_expr(src)
    if len(toks) == 0:
        return Value.none()
    var ev = Evaluator(toks, base_url)
    var v = ev.parse_expr(ctx, scopes)
    if ev.pos != len(ev.toks):
        raise Error("template expr: trailing tokens in '" + src + "'")
    return v^


# ---------- rendering ----------


def _render_nodes(
    doc: Doc,
    node: Int,
    mut ctx: Value,
    mut scopes: List[Value],
    mut env: TemplateEnv,
    base_url: String,
    depth: Int,
) raises -> String:
    var out = String()
    if depth > MAX_INCLUDE_DEPTH + 8:
        raise Error("template: render depth bound exceeded")
    ref n = doc.nodes[node]
    if n.kind == N_TEXT:
        return n.text.copy()
    if n.kind == N_OUTPUT:
        var v = eval_expr(n.text, ctx, scopes, base_url)
        if v.is_raw():
            return v.to_display()
        return escape_html(v.to_display())
    if n.kind == N_LIST or n.kind == N_BLOCK:
        for c in n.children:
            out += _render_nodes(doc, c, ctx, scopes, env, base_url, depth)
        return out^
    if n.kind == N_IF:
        for b in n.children:
            ref branch = doc.nodes[b]
            if branch.text == "":
                return _render_nodes(
                    doc, branch.children[0], ctx, scopes, env, base_url, depth
                )
            var cond = eval_expr(branch.text, ctx, scopes, base_url)
            if cond.truthy():
                return _render_nodes(
                    doc, branch.children[0], ctx, scopes, env, base_url, depth
                )
        return out^
    if n.kind == N_FOR:
        var iterable = eval_expr(n.aux, ctx, scopes, base_url)
        var count = 0
        if iterable.kind() == V_LIST:
            count = iterable.length()
        if count > MAX_LOOP_ITEMS:
            raise Error("template: loop bound exceeded")
        if count == 0:
            if len(n.children) > 1:
                return _render_nodes(
                    doc, n.children[1], ctx, scopes, env, base_url, depth
                )
            return out^
        for i in range(count):
            var scope = Value.dict(_stops(""), List[Value]())
            scope.set(n.text, iterable.at(i))
            var loop = Value.dict(_stops(""), List[Value]())
            loop.set("index", Value.integer(i + 1))
            loop.set("index0", Value.integer(i))
            loop.set("first", Value.boolean(i == 0))
            loop.set("last", Value.boolean(i == count - 1))
            loop.set("length", Value.integer(count))
            scope.set("loop", loop^)
            scopes.append(scope^)
            out += _render_nodes(
                doc, n.children[0], ctx, scopes, env, base_url, depth
            )
            _ = scopes.pop()
        return out^
    if n.kind == N_SET:
        var v2 = eval_expr(n.aux, ctx, scopes, base_url)
        if len(scopes) > 0:
            scopes[len(scopes) - 1].set(n.text, v2^)
        else:
            ctx.set(n.text, v2^)
        return out^
    if n.kind == N_INCLUDE:
        if depth + 1 > MAX_INCLUDE_DEPTH:
            raise Error("template: include depth bound exceeded")
        var sub = env.parsed(n.text)
        _check_no_extends(sub)
        return _render_nodes(sub, sub.root, ctx, scopes, env, base_url, depth + 1)
    raise Error("template: cannot render node kind " + String(n.kind))


def _check_no_extends(doc: Doc) raises:
    for ref nd in doc.nodes[doc.root].children:
        if doc.nodes[nd].kind == N_EXTENDS:
            raise Error("template: included/extended templates may not extend")


def render_parsed(
    doc: Doc, mut ctx: Value, mut env: TemplateEnv, base_url: String
) raises -> String:
    var scopes = List[Value]()
    return _render_nodes(doc, doc.root, ctx, scopes, env, base_url, 0)


def render_template(
    name: String, mut ctx: Value, mut env: TemplateEnv, base_url: String
) raises -> String:
    """Render the named template, resolving one level of extends."""
    var doc = env.parsed(name)
    var extends_name = String()
    for ref nd in doc.nodes[doc.root].children:
        if doc.nodes[nd].kind == N_EXTENDS:
            extends_name = doc.nodes[nd].text.copy()
    if extends_name == "":
        return render_parsed(doc, ctx, env, base_url)
    # Collect the child's top-level blocks, then parse the parent into the
    # same arena and rewire matching blocks to the child's bodies.
    var child_blocks = List[Int]()
    for ref nd in doc.nodes[doc.root].children:
        if doc.nodes[nd].kind == N_BLOCK:
            child_blocks.append(nd)
    var tokens = _tokenize(env.get(extends_name))
    var pos = 0
    var parent_start = len(doc.nodes)
    var parent_root = _parse_nodes(tokens, pos, doc, _stops(""))
    for ref nd in doc.nodes[parent_root].children:
        if doc.nodes[nd].kind == N_EXTENDS:
            raise Error("template: only one level of extends is supported")
    for bi in range(parent_start, len(doc.nodes)):
        if doc.nodes[bi].kind != N_BLOCK:
            continue
        for ref cb in child_blocks:
            if doc.nodes[cb].text == doc.nodes[bi].text:
                doc.nodes[bi].children = doc.nodes[cb].children.copy()
    var scopes = List[Value]()
    return _render_nodes(doc, parent_root, ctx, scopes, env, base_url, 0)


def render_string(
    source: String, mut ctx: Value, mut env: TemplateEnv, base_url: String
) raises -> String:
    var doc = parse_template(source)
    _check_no_extends(doc)
    return render_parsed(doc, ctx, env, base_url)
