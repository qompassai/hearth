"""Table of contents: the heading list a render collected, shaped as a
template Value — a flat list of {id, level, title} in document order.
(Phase 1 keeps it flat; nesting is presentational and templates can
group by level.)"""

from hearth.markdown import Heading
from hearth.value import Value


def toc_value(headings: List[Heading]) -> Value:
    var items = List[Value]()
    for ref h in headings:
        var keys = List[String]()
        var vals = List[Value]()
        keys.append("id")
        vals.append(Value.string(h.id))
        keys.append("level")
        vals.append(Value.integer(h.level))
        keys.append("title")
        vals.append(Value.string(h.text))
        items.append(Value.dict(keys, vals))
    return Value.list(items)
