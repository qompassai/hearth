"""Check stage (SPEC.md S5): validate a built output tree — every
internal link and anchor must resolve inside the tree.

Links considered: href/src attribute values that are site-absolute
(`/...`), relative, or fragment-only (`#id`). External URLs (scheme or
protocol-relative) are skipped by design. An internal path resolves if
the file exists, or it names a directory whose index.html exists.
Anchors resolve against the `id="..."` attributes of the target file.
"""

from hearth.assets import OutputFile, _collect_tree
from hearth.scan import join_path
from std.pathlib import Path


def _extract_attr_values(html: String, attr: String) -> List[String]:
    var values = List[String]()
    var needle = attr + '="'
    var pos = 0
    while True:
        var at = html.find(needle, pos)
        if at == -1:
            break
        var start = at + needle.byte_length()
        var end = html.find('"', start)
        if end == -1:
            break
        values.append(String(html[byte=start:end]))
        pos = end + 1
    return values^


def _is_external(url: String) -> Bool:
    return (
        url.startswith("http://")
        or url.startswith("https://")
        or url.startswith("//")
        or url.startswith("mailto:")
        or url.startswith("tel:")
        or url.startswith("data:")
    )


def _resolve_path(base_file_rel: String, url_path: String) -> String:
    """Resolve a link path against the file containing it, returning a
    normalized output-relative path (no leading slash, dot segments
    folded)."""
    var combined = url_path.copy()
    if not url_path.startswith("/"):
        var dir = base_file_rel.copy()
        var slash = dir.rfind("/")
        dir = String(dir[byte=:slash]) if slash != -1 else String()
        combined = dir + "/" + url_path if dir != "" else url_path
    var parts = List[String]()
    for ref seg in combined.split("/"):
        if seg == "" or seg == ".":
            continue
        if seg == "..":
            if len(parts) > 0:
                _ = parts.pop()
            continue
        parts.append(String(seg))
    return "/".join(parts)


def check_output(output_dir: String) raises -> List[String]:
    var files = List[OutputFile]()
    _collect_tree(output_dir, String(), files, 0)
    var present = List[String]()
    var html_files = List[OutputFile]()
    for ref f in files:
        present.append(f.rel_path.copy())
        if f.rel_path.endswith(".html"):
            html_files.append(f.copy())
    var problems = List[String]()
    for ref f in html_files:
        var ids = _extract_attr_values(f.content, "id")
        var links = _extract_attr_values(f.content, "href")
        var srcs = _extract_attr_values(f.content, "src")
        for ref src in srcs:
            links.append(src.copy())
        for ref url in links:
            if url == "" or _is_external(url):
                continue
            var frag = String()
            var path_part = url.copy()
            var hash_at = url.find("#")
            if hash_at != -1:
                frag = String(url[byte=hash_at + 1 :])
                path_part = String(url[byte=:hash_at])
            var target_rel = f.rel_path.copy()
            if path_part != "":
                target_rel = _resolve_path(f.rel_path, path_part)
                var found = False
                for ref p in present:
                    if p == target_rel:
                        found = True
                if not found:
                    var idx_path = "index.html"
                    if target_rel != "":
                        idx_path = target_rel + "/index.html"
                    for ref p in present:
                        if p == idx_path:
                            found = True
                            target_rel = idx_path
                if not found:
                    problems.append(
                        f.rel_path + ": broken link '" + url + "'"
                    )
                    continue
            if frag != "":
                var target_ids = ids.copy()
                if target_rel != f.rel_path:
                    target_ids = List[String]()
                    for ref tf in html_files:
                        if tf.rel_path == target_rel:
                            target_ids = _extract_attr_values(tf.content, "id")
                var ok = False
                for ref tid in target_ids:
                    if tid == frag:
                        ok = True
                if not ok:
                    problems.append(
                        f.rel_path + ": missing anchor '#" + frag + "'"
                    )
    return problems^
