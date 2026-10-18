"""Content scanning: walk `content/` with hard bounds (SPEC.md S3) and
classify Markdown files into sections (`_index.md`) and pages.

Deterministic by construction: directory entries are sorted before
traversal, so the scan order never depends on filesystem order.
"""

from std.pathlib import Path

comptime MAX_FILES: Int = 100_000
comptime MAX_DEPTH: Int = 32
comptime MAX_FILE_BYTES: Int = 64 << 20


def join_path(a: String, b: String) -> String:
    if a == "":
        return b.copy()
    if b == "":
        return a.copy()
    if a.endswith("/"):
        return a + b
    return a + "/" + b


def read_text_file(path: String) raises -> String:
    var text = open(path, "r").read()
    if text.byte_length() > MAX_FILE_BYTES:
        raise Error("scan: file exceeds size bound: " + path)
    return text^


struct ContentItem(Copyable, Movable):
    var is_section: Bool
    var slug_path: String  # "" for the root section; "a/b" otherwise
    var source_path: String  # absolute or root-relative file path
    var dir_files: List[String]  # names of every file in the same directory

    def __init__(
        out self,
        is_section: Bool,
        slug_path: String,
        source_path: String,
        dir_files: List[String],
    ):
        self.is_section = is_section
        self.slug_path = slug_path.copy()
        self.source_path = source_path.copy()
        self.dir_files = dir_files.copy()


struct ScanResult(Copyable, Movable):
    var items: List[ContentItem]
    var asset_files: List[String]  # non-Markdown files, content-root relative

    def __init__(out self):
        self.items = List[ContentItem]()
        self.asset_files = List[String]()


def _sorted_names(dir_path: String) raises -> List[String]:
    var names = List[String]()
    for entry in Path(dir_path).listdir():
        var full = String(entry)
        # listdir entries may be full paths or bare names; keep the name.
        var slash = full.rfind("/")
        if slash != -1:
            var tail = String(full[byte=slash + 1 :])
            full = tail^
        if full != "":
            names.append(full^)
    # Insertion sort (directory fan-out is small; the bound is MAX_FILES).
    for i in range(1, len(names)):
        var j = i
        while j > 0 and names[j] < names[j - 1]:
            var tmp = names[j - 1].copy()
            names[j - 1] = names[j].copy()
            names[j] = tmp^
            j -= 1
    return names^


def scan_content(content_dir: String) raises -> ScanResult:
    var result = ScanResult()
    # Stack of (directory path, slug prefix, depth).
    var stack_dirs = List[String]()
    var stack_slugs = List[String]()
    var stack_depths = List[Int]()
    stack_dirs.append(content_dir.copy())
    stack_slugs.append(String())
    stack_depths.append(0)
    while len(stack_dirs) > 0:
        var dir_path = stack_dirs.pop()
        var slug_prefix = stack_slugs.pop()
        var depth = stack_depths.pop()
        if depth > MAX_DEPTH:
            raise Error("scan: directory depth bound exceeded at " + dir_path)
        var names = _sorted_names(dir_path)
        # File names in this directory are not stored per item (a flat
        # 1,000-page directory would multiply the listing by the page
        # count); colocated assets come from the scan's asset list.
        var dir_files = List[String]()
        for ref name in names:
            if len(result.items) + len(result.asset_files) > MAX_FILES:
                raise Error("scan: file count bound exceeded")
            var full = join_path(dir_path, name)
            var p = Path(full)
            if p.is_dir():
                stack_dirs.append(full.copy())
                stack_slugs.append(
                    name.copy() if slug_prefix == "" else slug_prefix + "/" + name
                )
                stack_depths.append(depth + 1)
                continue
            if name == "_index.md":
                result.items.append(
                    ContentItem(True, slug_prefix, full, dir_files)
                )
            elif name.endswith(".md"):
                var stem = String(name[byte=: name.byte_length() - 3])
                var slug = stem if slug_prefix == "" else slug_prefix + "/" + stem
                result.items.append(ContentItem(False, slug, full, dir_files))
            else:
                var rel = name if slug_prefix == "" else slug_prefix + "/" + name
                result.asset_files.append(rel^)
    return result^
