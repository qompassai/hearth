"""Unit tests for hearth.markdown: the behaviors the site corpora and
SPEC.md S3 require, half validation / half adversarial."""

from hearth.markdown import render_html, render_markdown


struct Suite(Copyable, Movable):
    var passed: Int
    var failed: Int

    def __init__(out self):
        self.passed = 0
        self.failed = 0

    def expect(mut self, cond: Bool, name: String):
        if cond:
            self.passed += 1
            print("ok - " + name)
        else:
            self.failed += 1
            print("FAIL - " + name)

    def eq(mut self, got: String, want: String, name: String):
        if got == want:
            self.passed += 1
            print("ok - " + name)
        else:
            self.failed += 1
            print("FAIL - " + name + "\n  got:  " + got + "\n  want: " + want)

    def finish(self) raises:
        print(String(self.passed) + " passed, " + String(self.failed) + " failed")
        if self.failed > 0:
            raise Error("test_markdown: failures present")


def main() raises:
    var s = Suite()
    # Validation.
    s.eq(render_markdown("# Hello\n", site_extensions=True).html, '<h1 id="hello">Hello</h1>\n', "atx heading with id")
    s.eq(render_html("Hello *world*\n"), "<p>Hello <em>world</em></p>\n", "em")
    s.eq(render_html("a **b** c\n"), "<p>a <strong>b</strong> c</p>\n", "strong")
    s.eq(render_html("`x < y`\n"), "<p><code>x &lt; y</code></p>\n", "code span escapes")
    s.eq(render_html("[t](/u \"T\")\n"), '<p><a href="/u" title="T">t</a></p>\n', "inline link with title")
    s.eq(render_html("- a\n- b\n"), "<ul>\n<li>a\n</li>\n<li>b\n</li>\n</ul>\n", "tight list")
    s.eq(
        render_html("| A | B |\n|---|---|\n| 1 | 2 |\n"),
        "<table>\n<thead>\n<tr>\n<th>A</th>\n<th>B</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>1</td>\n<td>2</td>\n</tr>\n</tbody>\n</table>\n",
        "table",
    )
    s.eq(render_html("> hi\n"), "<blockquote>\n<p>hi</p>\n</blockquote>\n", "blockquote")
    s.eq(render_html("```\nx\n```\n"), "<pre><code>x\n</code></pre>\n", "fence")
    s.eq(render_markdown("Title\n===\n", site_extensions=True).html, '<h1 id="title">Title</h1>\n', "setext h1 with id")
    s.eq(render_html("a ~~b~~ c\n"), "<p>a <del>b</del> c</p>\n", "strikethrough")
    s.eq(render_html("[a][x]\n\n[x]: /u\n"), '<p><a href="/u">a</a></p>\n', "reference link")
    s.eq(render_html("a  \nb\n"), "<p>a<br />\nb</p>\n", "hard break")
    s.eq(render_html("5 & 6 < 7\n"), "<p>5 &amp; 6 &lt; 7</p>\n", "text escaping")
    # Adversarial.
    s.eq(render_html("####### not a heading\n"), "<p>####### not a heading</p>\n", "seven hashes is a paragraph")
    s.eq(render_html("[a][missing]\n"), "<p>[a][missing]</p>\n", "unknown reference stays literal")
    s.eq(render_html("`unclosed\n"), "<p>`unclosed</p>\n", "unclosed code span stays literal")
    s.eq(render_html("**b *c* d**\n"), "<p><strong>b <em>c</em> d</strong></p>\n", "em inside strong")
    s.eq(render_html("a_b_c\n"), "<p>a_b_c</p>\n", "intraword underscore is literal")
    s.eq(render_html("&unknownentity;\n"), "<p>&amp;unknownentity;</p>\n", "unknown entity stays literal")
    s.eq(render_html("&#65;&#x42;\n"), "<p>AB</p>\n", "numeric entities decode")
    s.eq(render_markdown("# Dup\n\n# Dup\n", site_extensions=True).html, '<h1 id="dup">Dup</h1>\n<h1 id="dup-1">Dup</h1>\n', "duplicate heading ids are suffixed")
    s.finish()
