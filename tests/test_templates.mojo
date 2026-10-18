"""Unit tests for hearth.templates: the SPEC.md S3 subset, including the
exact constructs the frozen corpora exercise."""

from hearth.templates import TemplateEnv, render_string, render_template
from hearth.value import Value


struct Suite(Copyable, Movable):
    var passed: Int
    var failed: Int

    def __init__(out self):
        self.passed = 0
        self.failed = 0

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
            raise Error("test_templates: failures present")


def _ctx() -> Value:
    var root = Value.dict(List[String](), List[Value]())
    var section = Value.dict(List[String](), List[Value]())
    section.set("title", Value.string("Hello <World>"))
    var content = Value.string("<p>body</p>")
    content.set_raw(True)
    section.set("content", content^)
    var extra = Value.dict(List[String](), List[Value]())
    var authors = List[Value]()
    var a1 = Value.dict(List[String](), List[Value]())
    a1.set("name", Value.string("Ann"))
    a1.set("url", Value.string("https://a.example"))
    authors.append(a1^)
    var a2 = Value.dict(List[String](), List[Value]())
    a2.set("name", Value.string("Bob"))
    a2.set("url", Value.string(""))
    authors.append(a2^)
    extra.set("authors", Value.list(authors))
    section.set("extra", extra^)
    root.set("section", section^)
    return root^


def main() raises:
    var s = Suite()
    var env = TemplateEnv()
    var ctx = _ctx()
    # Validation: the corpus constructs.
    s.eq(render_string("{{ section.title }}", ctx, env, "/"), "Hello &lt;World&gt;", "output escapes by default")
    s.eq(render_string("{{ section.content }}", ctx, env, "/"), "<p>body</p>", "raw value renders verbatim")
    s.eq(render_string("{{ section.content | safe }}", ctx, env, "/"), "<p>body</p>", "safe filter")
    s.eq(
        render_string("{% for author in section.extra.authors %}{{ author.name }};{% endfor %}", ctx, env, "/"),
        "Ann;Bob;",
        "for over nested list",
    )
    s.eq(
        render_string("{% for author in section.extra.authors %}{% if author.url %}[{{ author.name }}]({{ author.url }}){% else %}{{ author.name }}{% endif %} {% endfor %}", ctx, env, "/"),
        "[Ann](https://a.example) Bob ",
        "if/else on empty-string falsiness",
    )
    s.eq(
        render_string("{% for author in section.extra.authors %}{{ loop.index }}{% if loop.last %}!{% endif %}{% endfor %}", ctx, env, "/"),
        "12!",
        "loop.index and loop.last",
    )
    s.eq(render_string("{{ get_url(path='style.css') }}", ctx, env, "https://x.example/"), "https://x.example/style.css", "get_url joins base and path")
    s.eq(render_string("{{ section.missing | default(value='fallback') }}", ctx, env, "/"), "fallback", "missing key plus default filter")
    s.eq(render_string("{{ section.extra.authors | length }}", ctx, env, "/"), "2", "length filter")
    # Include and one level of extends.
    var env2 = TemplateEnv()
    env2.add("base.html", "<html>{% block body %}base{% endblock %}</html>")
    env2.add("child.html", "{% extends \"base.html\" %}{% block body %}child {{ section.title }}{% endblock %}")
    env2.add("frag.html", "<b>frag</b>")
    s.eq(render_template("child.html", ctx, env2, "/"), "<html>child Hello &lt;World&gt;</html>", "extends with block override")
    s.eq(render_string("A{% include \"frag.html\" %}B", ctx, env2, "/"), "A<b>frag</b>B", "include")
    # Adversarial.
    s.eq(render_string("{% if section.missing %}Y{% else %}N{% endif %}", ctx, env, "/"), "N", "missing key is falsy, not an error")
    s.eq(render_string("{% set x = 40 + 2 %}{{ x }}", ctx, env, "/"), "42", "set with arithmetic")
    s.eq(render_string("{{ 'a' ~ 'b' }}", ctx, env, "/"), "ab", "concatenation operator")
    var raised = False
    try:
        _ = render_string("{{ section.title | nosuchfilter }}", ctx, env, "/")
    except:
        raised = True
    if raised:
        s.passed += 1
        print("ok - unknown filter raises")
    else:
        s.failed += 1
        print("FAIL - unknown filter raises")
    s.finish()
