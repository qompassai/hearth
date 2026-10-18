"""Render stage (SPEC.md S5): site configuration and the page/section
context values templates see.

Config is Hearth's own `hearth.toml` at the site root (base_url, title,
description, plus anything else, exposed to templates as `config`).
Zola's `zola.toml` is never read as config — the frozen corpora carry
their rendering contract in their templates and content, and the bench
harness reads base_url from zola.toml only to pass it via --base-url.
"""

from hearth.config import parse_toml
from hearth.scan import join_path, read_text_file
from hearth.value import Value
from std.pathlib import Path


def load_site_config(source_dir: String, base_url_override: String) raises -> Value:
    var cfg_path = join_path(source_dir, "hearth.toml")
    var cfg = Value.dict(List[String](), List[Value]())
    if Path(cfg_path).exists():
        cfg = parse_toml(read_text_file(cfg_path))
    if base_url_override != "":
        cfg.set("base_url", Value.string(base_url_override))
    if cfg.get("base_url").is_none():
        cfg.set("base_url", Value.string("/"))
    if cfg.get("title").is_none():
        cfg.set("title", Value.string(""))
    if cfg.get("description").is_none():
        cfg.set("description", Value.string(""))
    return cfg^


def permalink_for(base_url: String, slug_path: String) -> String:
    """base_url joined with the item's path: the root is the base itself
    (with a trailing slash), anything else is base + slug + '/'."""
    var b = base_url.copy()
    while b.endswith("/") and b.byte_length() > 1:
        var tail = String(b[byte=: b.byte_length() - 1])
        b = tail^
    if slug_path == "":
        return b + "/"
    return b + "/" + slug_path + "/"


def url_path_for(slug_path: String) -> String:
    if slug_path == "":
        return "/"
    return "/" + slug_path + "/"


def word_count(text: String) -> Int:
    var count = 0
    var in_word = False
    for b in text.as_bytes():
        var ws = b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D
        if ws:
            in_word = False
        elif not in_word:
            in_word = True
            count += 1
    return count
