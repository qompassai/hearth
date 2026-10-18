"""Asset stage (SPEC.md S5): everything that is not a rendered page —
`static/` copied to the output root, and files colocated with content
copied beside their page/section output.

Phase 1 limitation, stated plainly: files are carried as text. The
frozen corpora's assets are text (CSS, SVG, TOML); a binary asset would
be corrupted. Binary-safe IO is a named follow-up in the Phase 1
report, not a silent behavior.
"""

from hearth.scan import join_path, read_text_file
from hearth.value import Value
from std.pathlib import Path

comptime MAX_ASSET_FILES: Int = 100_000


struct OutputFile(Copyable, Movable):
    var rel_path: String  # path relative to the output root
    var content: String

    def __init__(out self, rel_path: String, content: String):
        self.rel_path = rel_path.copy()
        self.content = content.copy()


def _collect_tree(
    src_dir: String, rel_prefix: String, mut out: List[OutputFile], depth: Int
) raises:
    if depth > 32:
        raise Error("assets: directory depth bound exceeded at " + src_dir)
    if len(out) > MAX_ASSET_FILES:
        raise Error("assets: file count bound exceeded")
    var names = List[String]()
    for entry in Path(src_dir).listdir():
        var full = String(entry)
        var slash = full.rfind("/")
        if slash != -1:
            var tail = String(full[byte=slash + 1 :])
            full = tail^
        if full != "":
            names.append(full^)
    for i in range(1, len(names)):
        var j = i
        while j > 0 and names[j] < names[j - 1]:
            var tmp = names[j - 1].copy()
            names[j - 1] = names[j].copy()
            names[j] = tmp^
            j -= 1
    for ref name in names:
        var full = join_path(src_dir, name)
        var rel = name if rel_prefix == "" else rel_prefix + "/" + name
        if Path(full).is_dir():
            _collect_tree(full, rel, out, depth + 1)
        else:
            out.append(OutputFile(rel, read_text_file(full)))


def collect_static(source_dir: String, mut out: List[OutputFile]) raises:
    var static_dir = join_path(source_dir, "static")
    if Path(static_dir).exists():
        _collect_tree(static_dir, String(), out, 0)


def collect_colocated(
    content_dir: String,
    rel_path: String,
    out_dir_rel: String,
    mut out: List[OutputFile],
) raises:
    """One colocated asset: content/<rel_path> → output/<out_dir_rel>/<name>."""
    var name = rel_path.copy()
    var slash = name.rfind("/")
    if slash != -1:
        var tail2 = String(name[byte=slash + 1 :])
        name = tail2^
    var target = name if out_dir_rel == "" else out_dir_rel + "/" + name
    out.append(
        OutputFile(target, read_text_file(join_path(content_dir, rel_path)))
    )
