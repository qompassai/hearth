"""Hearth's shared value model.

A `Value` is a recursive document value (none / bool / int / float /
string / list / dict) stored as a flat node arena: Mojo structs cannot
hold `List[Self]` fields (the field is not Deinitable), so each Value
owns the arena for its whole tree and `root` indexes into it. The same
pattern is used by mojo-template's TemplateValue.

Values are the currency of the pipeline: the TOML-subset parser in
`config` produces them, `frontmatter` returns them, and `templates`
consumes them as render contexts.

The `raw` flag on a node marks a string as pre-rendered HTML that the
template engine must not escape (page/section `content`, shortcode
`body`). It mirrors what Zola does implicitly for those fields.
"""

comptime V_NONE: Int = 0
comptime V_BOOL: Int = 1
comptime V_INT: Int = 2
comptime V_FLOAT: Int = 3
comptime V_STRING: Int = 4
comptime V_LIST: Int = 5
comptime V_DICT: Int = 6


struct Node(Copyable, Movable):
    var kind: Int
    var b: Bool
    var i: Int
    var f: Float64
    var s: String
    var raw: Bool
    var children: List[Int]
    var keys: List[String]

    def __init__(out self, kind: Int):
        self.kind = kind
        self.b = False
        self.i = 0
        self.f = 0.0
        self.s = String()
        self.raw = False
        self.children = List[Int]()
        self.keys = List[String]()


struct Value(Copyable, Movable):
    var nodes: List[Node]
    var root: Int

    def __init__(out self):
        self.nodes = List[Node]()
        self.nodes.append(Node(V_NONE))
        self.root = 0

    @staticmethod
    def none() -> Value:
        return Value()

    @staticmethod
    def boolean(b: Bool) -> Value:
        var v = Value()
        v.nodes[0].kind = V_BOOL
        v.nodes[0].b = b
        return v^

    @staticmethod
    def integer(i: Int) -> Value:
        var v = Value()
        v.nodes[0].kind = V_INT
        v.nodes[0].i = i
        return v^

    @staticmethod
    def floating(f: Float64) -> Value:
        var v = Value()
        v.nodes[0].kind = V_FLOAT
        v.nodes[0].f = f
        return v^

    @staticmethod
    def string(s: String, raw: Bool = False) -> Value:
        var v = Value()
        v.nodes[0].kind = V_STRING
        v.nodes[0].s = s.copy()
        v.nodes[0].raw = raw
        return v^

    @staticmethod
    def list(items: List[Value]) -> Value:
        var v = Value()
        v.nodes[0].kind = V_LIST
        for ref item in items:
            var idx = v._absorb(item)
            v.nodes[0].children.append(idx)
        return v^

    @staticmethod
    def dict(keys: List[String], vals: List[Value]) -> Value:
        var v = Value()
        v.nodes[0].kind = V_DICT
        debug_assert(len(keys) == len(vals), "dict keys/vals length mismatch")
        for n in range(len(keys)):
            var idx = v._absorb(vals[n])
            v.nodes[0].children.append(idx)
            v.nodes[0].keys.append(keys[n].copy())
        return v^

    def _absorb(mut self, child: Value) -> Int:
        """Append `child`'s arena into self, offsetting indices; return the
        child's new root index."""
        var offset = len(self.nodes)
        for ref node in child.nodes:
            var copy = node.copy()
            for j in range(len(copy.children)):
                copy.children[j] += offset
            self.nodes.append(copy^)
        return offset + child.root

    def _node(self) -> Node:
        return self.nodes[self.root].copy()

    def kind(self) -> Int:
        return self.nodes[self.root].kind

    def is_none(self) -> Bool:
        return self.kind() == V_NONE

    def truthy(self) -> Bool:
        var kind = self.nodes[self.root].kind
        if kind == V_NONE:
            return False
        if kind == V_BOOL:
            return self.nodes[self.root].b
        if kind == V_INT:
            return self.nodes[self.root].i != 0
        if kind == V_FLOAT:
            return self.nodes[self.root].f != 0.0
        if kind == V_STRING:
            return self.nodes[self.root].s.byte_length() > 0
        if kind == V_LIST or kind == V_DICT:
            return len(self.nodes[self.root].children) > 0
        return False

    def as_bool(self) -> Bool:
        return self.nodes[self.root].b

    def as_int(self) -> Int:
        if self.nodes[self.root].kind == V_FLOAT:
            return Int(self.nodes[self.root].f)
        return self.nodes[self.root].i

    def as_float(self) -> Float64:
        if self.nodes[self.root].kind == V_INT:
            return Float64(self.nodes[self.root].i)
        return self.nodes[self.root].f

    def as_string(self) -> String:
        return self.nodes[self.root].s.copy()

    def is_raw(self) -> Bool:
        return self.nodes[self.root].raw

    def set_raw(mut self, raw: Bool):
        self.nodes[self.root].raw = raw

    def length(self) -> Int:
        var kind = self.nodes[self.root].kind
        if kind == V_STRING:
            return self.nodes[self.root].s.byte_length()
        if kind == V_LIST or kind == V_DICT:
            return len(self.nodes[self.root].children)
        return 0

    def _extract(self, idx: Int) -> Value:
        """Materialise the subtree at arena index `idx` as its own Value.

        The remap table covers only the subtree (visit order), never the
        whole arena: extraction cost stays proportional to the subtree,
        which is what keeps `get`/`at` cheap on site-sized contexts."""
        var out = Value()
        out.nodes.clear()
        var old_ids = List[Int]()
        var stack = List[Int]()
        stack.append(idx)
        while len(stack) > 0:
            var cur = stack.pop()
            old_ids.append(cur)
            out.nodes.append(self.nodes[cur].copy())
            for c in self.nodes[cur].children:
                stack.append(c)
        if len(old_ids) > 32:
            var map = Dict[Int, Int]()
            for t in range(len(old_ids)):
                map[old_ids[t]] = t
            for k in range(len(out.nodes)):
                for j in range(len(out.nodes[k].children)):
                    out.nodes[k].children[j] = map.get(
                        out.nodes[k].children[j], -1
                    )
        else:
            for k in range(len(out.nodes)):
                for j in range(len(out.nodes[k].children)):
                    var old = out.nodes[k].children[j]
                    for t in range(len(old_ids)):
                        if old_ids[t] == old:
                            out.nodes[k].children[j] = t
                            break
        out.root = 0
        return out^

    def get(self, key: String) -> Value:
        """Dict lookup; a missing key yields none (never raises)."""
        if self.nodes[self.root].kind != V_DICT:
            return Value.none()
        for j in range(len(self.nodes[self.root].keys)):
            if self.nodes[self.root].keys[j] == key:
                return self._extract(self.nodes[self.root].children[j])
        return Value.none()

    def has(self, key: String) -> Bool:
        if self.nodes[self.root].kind != V_DICT:
            return False
        for j in range(len(self.nodes[self.root].keys)):
            if self.nodes[self.root].keys[j] == key:
                return True
        return False

    def keys(self) -> List[String]:
        var out = List[String]()
        if self.nodes[self.root].kind == V_DICT:
            for ref k in self.nodes[self.root].keys:
                out.append(k.copy())
        return out^

    def at(self, idx: Int) -> Value:
        var kind = self.nodes[self.root].kind
        if (kind == V_LIST or kind == V_DICT) and (
            0 <= idx < len(self.nodes[self.root].children)
        ):
            return self._extract(self.nodes[self.root].children[idx])
        return Value.none()

    def set(mut self, key: String, var value: Value):
        """Set a dict key on the root node (root must be a dict)."""
        debug_assert(self.kind() == V_DICT, "Value.set on non-dict")
        var idx = self._absorb(value^)
        for j in range(len(self.nodes[self.root].keys)):
            if self.nodes[self.root].keys[j] == key:
                self.nodes[self.root].children[j] = idx
                return
        self.nodes[self.root].children.append(idx)
        self.nodes[self.root].keys.append(key.copy())

    def push(mut self, var value: Value):
        """Append to a list root."""
        debug_assert(self.kind() == V_LIST, "Value.push on non-list")
        var idx = self._absorb(value^)
        self.nodes[self.root].children.append(idx)

    def to_display(self) -> String:
        """Scalar rendering used by template output: strings as-is, numbers
        in plain form, bools as true/false, none and containers as empty."""
        var kind = self.nodes[self.root].kind
        if kind == V_STRING:
            return self.nodes[self.root].s.copy()
        if kind == V_BOOL:
            return String("true") if self.nodes[self.root].b else String("false")
        if kind == V_INT:
            return String(self.nodes[self.root].i)
        if kind == V_FLOAT:
            return String(self.nodes[self.root].f)
        return String()

    def equals(self, other: Value) -> Bool:
        var a_kind = self.nodes[self.root].kind
        var b_kind = other.nodes[other.root].kind
        if a_kind != b_kind:
            if (a_kind == V_INT and b_kind == V_FLOAT) or (
                a_kind == V_FLOAT and b_kind == V_INT
            ):
                return self.as_float() == other.as_float()
            return False
        if a_kind == V_BOOL:
            return self.nodes[self.root].b == other.nodes[other.root].b
        if a_kind == V_INT:
            return self.nodes[self.root].i == other.nodes[other.root].i
        if a_kind == V_FLOAT:
            return self.nodes[self.root].f == other.nodes[other.root].f
        if a_kind == V_STRING:
            return self.nodes[self.root].s == other.nodes[other.root].s
        if a_kind == V_NONE:
            return True
        if a_kind == V_LIST or a_kind == V_DICT:
            if len(self.nodes[self.root].children) != len(
                other.nodes[other.root].children
            ):
                return False
            if a_kind == V_DICT and (
                self.nodes[self.root].keys != other.nodes[other.root].keys
            ):
                return False
            for j in range(len(self.nodes[self.root].children)):
                if not self.at(j).equals(other.at(j)):
                    return False
            return True
        return False
