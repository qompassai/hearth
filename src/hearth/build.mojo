"""Build orchestration (SPEC.md S5 stage order): config → frontmatter →
scan → markdown → shortcodes → toc → templates → assets → write →
check. The check stage runs after every build; its problems are
returned, not hidden.
"""

from hearth.assets import OutputFile, _collect_tree, collect_static
from hearth.check import check_output
from hearth.config import parse_toml
from hearth.frontmatter import split_frontmatter
from hearth.markdown import render_markdown
from hearth.render import (
    load_site_config,
    permalink_for,
    url_path_for,
    word_count,
)
from hearth.scan import ContentItem, join_path, read_text_file, scan_content
from hearth.shortcodes import expand_shortcodes
from hearth.templates import TemplateEnv, render_template
from hearth.toc import toc_value
from hearth.value import Value, V_DICT, V_LIST
from hearth.write import materialize
from std.pathlib import Path


struct BuildResult(Copyable, Movable):
    var output_dir: String
    var files_written: Int
    var pages: Int
    var sections: Int
    var problems: List[String]

    def __init__(out self):
        self.output_dir = String()
        self.files_written = 0
        self.pages = 0
        self.sections = 0
        self.problems = List[String]()


def _load_templates(source_dir: String) raises -> TemplateEnv:
    var env = TemplateEnv()
    var tdir = join_path(source_dir, "templates")
    if not Path(tdir).exists():
        return env^
    var files = List[OutputFile]()
    _collect_tree(tdir, String(), files, 0)
    for ref f in files:
        env.add(f.rel_path, f.content)
    return env^


def _assets_for(item: ContentItem, asset_files: List[String]) -> List[Value]:
    """Colocated asset names for an item: the non-Markdown files in its
    own directory (content-relative scan paths filtered by directory)."""
    var dir = item.slug_path.copy()
    if not item.is_section:
        var slash = dir.rfind("/")
        if slash != -1:
            var dhead = String(dir[byte=:slash])
            dir = dhead^
        else:
            dir = String()
    var out = List[Value]()
    for ref rel in asset_files:
        var parent = rel.copy()
        var slash2 = parent.rfind("/")
        if slash2 != -1:
            var phead = String(parent[byte=:slash2])
            parent = phead^
        else:
            parent = String()
        if parent == dir:
            var name = rel.copy()
            var slash3 = name.rfind("/")
            if slash3 != -1:
                var ntail = String(name[byte=slash3 + 1 :])
                name = ntail^
            out.append(Value.string(name))
    return out^


def _base_context(
    fm: Value,
    item: ContentItem,
    md_html: String,
    headings_value: Value,
    cfg: Value,
    words: Int,
    item_assets: List[Value],
) -> Value:
    """Start from the front matter (so custom fields carry through), then
    set the computed fields."""
    var ctx = fm.copy()
    if ctx.kind() != V_DICT:
        ctx = Value.dict(List[String](), List[Value]())
    var content = Value.string(md_html)
    content.set_raw(True)
    ctx.set("content", content^)
    ctx.set("slug", Value.string(item.slug_path))
    ctx.set("path", Value.string(url_path_for(item.slug_path)))
    ctx.set(
        "permalink",
        Value.string(permalink_for(cfg.get("base_url").to_display(), item.slug_path)),
    )
    ctx.set("toc", headings_value.copy())
    ctx.set("word_count", Value.integer(words))
    ctx.set("reading_time", Value.integer((words + 199) // 200))
    if ctx.get("title").is_none():
        ctx.set("title", Value.string(""))
    if ctx.get("description").is_none():
        ctx.set("description", Value.string(""))
    if ctx.get("extra").kind() != V_DICT:
        ctx.set("extra", Value.dict(List[String](), List[Value]()))
    if ctx.get("assets").kind() != V_LIST:
        ctx.set("assets", Value.list(item_assets.copy()))
    return ctx^


def build_site(
    source_dir: String, output_override: String, base_url_override: String
) raises -> BuildResult:
    var cfg = load_site_config(source_dir, base_url_override)
    var base_url = cfg.get("base_url").to_display()
    var env = _load_templates(source_dir)
    var content_dir = join_path(source_dir, "content")
    var scan = scan_content(content_dir)

    # First pass: build every item's context value.
    var contexts = List[Value]()
    var bodies = List[String]()
    for ref item in scan.items:
        var raw_text = read_text_file(item.source_path)
        var split = split_frontmatter(raw_text)
        var fm = split[1].copy()
        var body = split[2].copy()
        var expanded = expand_shortcodes(body, env, base_url)
        var md = render_markdown(expanded, site_extensions=True)
        var ctx = _base_context(
            fm,
            item,
            md.html,
            toc_value(md.headings),
            cfg,
            word_count(expanded),
            _assets_for(item, scan.asset_files),
        )
        contexts.append(ctx^)
        bodies.append(expanded^)

    # Second pass: sections learn their child pages (direct children,
    # sorted by path — Zola's default section ordering here is path
    # order; a page's own sort key is available via its front matter).
    for si in range(len(scan.items)):
        if not scan.items[si].is_section:
            continue
        var sec_dir = scan.items[si].slug_path
        var page_values = List[Value]()
        var sub_values = List[Value]()
        for pi in range(len(scan.items)):
            var it = scan.items[pi].copy()
            if pi == si:
                continue
            # Direct child: the item's directory equals the section's.
            var parent = it.slug_path.copy()
            var slash = parent.rfind("/")
            parent = String(parent[byte=:slash]) if slash != -1 else String()
            if not it.is_section and parent == sec_dir:
                page_values.append(contexts[pi].copy())
            if it.is_section and parent == sec_dir:
                sub_values.append(contexts[pi].copy())
        # Sort pages by path. Keys are extracted once up front: Value.get
        # materializes a subtree, so calling it inside the comparison
        # loop would make the sort quadratic in arena copies.
        var keys = List[String]()
        for ref pv in page_values:
            keys.append(pv.get("path").to_display())
        for a in range(1, len(page_values)):
            var b = a
            while b > 0 and keys[b] < keys[b - 1]:
                var tmp = page_values[b - 1].copy()
                page_values[b - 1] = page_values[b].copy()
                page_values[b] = tmp^
                var tk = keys[b - 1].copy()
                keys[b - 1] = keys[b].copy()
                keys[b] = tk^
                b -= 1
        contexts[si].set("pages", Value.list(page_values))
        contexts[si].set("subsections", Value.list(sub_values))

    # Third pass: render and collect outputs.
    var outputs = List[OutputFile]()
    collect_static(source_dir, outputs)
    # Colocated content assets land at their content-relative path, which
    # is exactly beside the owning page/section output.
    for ref rel in scan.asset_files:
        outputs.append(
            OutputFile(rel, read_text_file(join_path(content_dir, rel)))
        )
    var result = BuildResult()
    for i in range(len(scan.items)):
        var item = scan.items[i].copy()
        var ctx = contexts[i].copy()
        var template_name = ctx.get("template").to_display()
        if template_name == "":
            if item.is_section:
                template_name = (
                    "section.html" if env.has("section.html") else "index.html"
                )
            else:
                template_name = (
                    "page.html" if env.has("page.html") else "index.html"
                )
        var render_ctx = Value.dict(List[String](), List[Value]())
        render_ctx.set("config", cfg.copy())
        if item.is_section:
            render_ctx.set("section", ctx.copy())
        else:
            render_ctx.set("page", ctx.copy())
        var html = render_template(template_name, render_ctx, env, base_url)
        var out_rel = (
            "index.html"
            if item.slug_path == ""
            else item.slug_path + "/index.html"
        )
        outputs.append(OutputFile(out_rel, html))
        if item.is_section:
            result.sections += 1
        else:
            result.pages += 1
    # Zola-compatible generated files: a 404 page (the site's own
    # templates/404.html when present, else the reference default) and a
    # robots.txt, each only when nothing else produced that path.
    var have_404 = False
    var have_robots = False
    for ref o in outputs:
        if o.rel_path == "404.html":
            have_404 = True
        if o.rel_path == "robots.txt":
            have_robots = True
    if not have_404:
        if env.has("404.html"):
            var ctx404 = Value.dict(List[String](), List[Value]())
            ctx404.set("config", cfg.copy())
            outputs.append(
                OutputFile(
                    "404.html", render_template("404.html", ctx404, env, base_url)
                )
            )
        else:
            outputs.append(
                OutputFile(
                    "404.html",
                    String(
                        "<!doctype html>\n<title>404 Not Found</title>\n"
                        + "<h1>404 Not Found</h1>\n"
                    ),
                )
            )
    if not have_robots:
        var robots = String("User-agent: *\nDisallow:\nAllow: /\nSitemap: ")
        if base_url.endswith("/"):
            robots += base_url + "sitemap.xml\n"
        else:
            robots += base_url + "/sitemap.xml\n"
        outputs.append(OutputFile("robots.txt", robots))
    result.output_dir = (
        output_override if output_override != "" else join_path(source_dir, "public")
    )
    result.files_written = len(outputs)
    materialize(outputs, result.output_dir)
    result.problems = check_output(result.output_dir)
    return result^
