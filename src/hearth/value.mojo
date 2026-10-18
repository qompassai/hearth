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
        var n = self._node()
        if n.kind == V_NONE:
            return False
        if n.kind == V_BOOL:
            return n.b
        if n.kind == V_INT:
            return n.i != 0
        if n.kind == V_FLOAT:
            return n.f != 0.0
        if n.kind == V_STRING:
            return n.s.byte_length() > 0
        if n.kind == V_LIST or n.kind == V_DICT:
            return len(n.children) > 0
        return False

    def as_bool(self) -> Bool:
        return self.nodes[self.root].b

    def as_int(self) -> Int:
        var n = self._node()
        if n.kind == V_FLOAT:
            return Int(n.f)
        return n.i

    def as_float(self) -> Float64:
        var n = self._node()
        if n.kind == V_INT:
            return Float64(n.i)
        return n.f

    def as_string(self) -> String:
        return self.nodes[self.root].s.copy()

    def is_raw(self) -> Bool:
        return self.nodes[self.root].raw

    def set_raw(mut self, raw: Bool):
        self.nodes[self.root].raw = raw

    def length(self) -> Int:
        var n = self._node()
        if n.kind == V_STRING:
            return n.s.byte_length()
        if n.kind == V_LIST or n.kind == V_DICT:
            return len(n.children)
        return 0

    def _extract(self, idx: Int) -> Value:
        """Materialise the subtree at arena index `idx` as its own Value."""
        var out = Value()
        out.nodes.clear()
        var map = List[Int]()
        for _ in range(len(self.nodes)):
            map.append(-1)
        var stack = List[Int]()
        stack.append(idx)
        map[idx] = 0
        var order = List[Int]()
        while len(stack) > 0:
            var cur = stack.pop()
            order.append(cur)
            var node = self.nodes[cur].copy()
            var new_idx = len(out.nodes)
            map[cur] = new_idx
            out.nodes.append(node^)
            for c in self.nodes[cur].children:
                stack.append(c)
        for k in range(len(out.nodes)):
            for j in range(len(out.nodes[k].children)):
                out.nodes[k].children[j] = map[out.nodes[k].children[j]]
        out.root = 0
        return out^

    def get(self, key: String) -> Value:
        """Dict lookup; a missing key yields none (never raises)."""
        var n = self._node()
        if n.kind != V_DICT:
            return Value.none()
        for j in range(len(n.keys)):
            if n.keys[j] == key:
                return self._extract(n.children[j])
        return Value.none()

    def has(self, key: String) -> Bool:
        var n = self._node()
        if n.kind != V_DICT:
            return False
        for j in range(len(n.keys)):
            if n.keys[j] == key:
                return True
        return False

    def keys(self) -> List[String]:
        var n = self._node()
        var out = List[String]()
        for ref k in n.keys:
            out.append(k.copy())
        return out^

    def at(self, idx: Int) -> Value:
        var n = self._node()
        if (n.kind == V_LIST or n.kind == V_DICT) and 0 <= idx < len(n.children):
            return self._extract(n.children[idx])
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
        var n = self._node()
        if n.kind == V_STRING:
            return n.s.copy()
        if n.kind == V_BOOL:
            return String("true") if n.b else String("false")
        if n.kind == V_INT:
            return String(n.i)
        if n.kind == V_FLOAT:
            return String(n.f)
        return String()

    def equals(self, other: Value) -> Bool:
        var a = self._node()
        var b = other._node()
        if a.kind != b.kind:
            if (a.kind == V_INT and b.kind == V_FLOAT) or (
                a.kind == V_FLOAT and b.kind == V_INT
            ):
                return self.as_float() == other.as_float()
            return False
        if a.kind == V_BOOL:
            return a.b == b.b
        if a.kind == V_INT:
            return a.i == b.i
        if a.kind == V_FLOAT:
            return a.f == b.f
        if a.kind == V_STRING:
            return a.s == b.s
        if a.kind == V_NONE:
            return True
        if a.kind == V_LIST or a.kind == V_DICT:
            if len(a.children) != len(b.children):
                return False
            if a.kind == V_DICT and a.keys != b.keys:
                return False
            for j in range(len(a.children)):
                if not self.at(j).equals(other.at(j)):
                    return False
            return True
        return False
