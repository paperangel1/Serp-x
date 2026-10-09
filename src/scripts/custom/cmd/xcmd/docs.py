"""Node reference generated from the schema (design §10): the docs cannot drift from what the engine supports."""
import os

from . import paths, ptypes as T

CAT = {"ru": {"event": "События", "action": "Действия", "logic": "Логика", "data": "Данные", "ui": "Интерфейс", "function": "Функции"},
       "en": {"event": "Events", "action": "Actions", "logic": "Logic", "data": "Data", "ui": "Interface", "function": "Functions"}}
FLOW = {"ru": {"event": "событие (запускает команду)", "action": "действие (идёт по проводу порядка выполнения)",
               "pure": "данные (считается по требованию)", "latent": "ожидание (может ждать)"},
        "en": {"event": "event (starts the command)", "action": "action (follows the execution wire)",
               "pure": "data (computed on demand)", "latent": "latent (may wait)"}}
HEAD = {"ru": {"pin": "Пин", "dir": "Направление", "type": "Тип", "label": "Подпись", "default": "По умолчанию",
               "in": "вход", "out": "выход", "example": "Пример", "caps": "Права", "flow": "Вид", "undo": "Откат",
               "danger": "Опасность", "none": "нет", "title": "Справочник узлов «Команд»", "state": "Меняет состояние",
               "yes": "да", "no": "нет", "deferred": "Узел пока недоступен: исполнитель появится позже."},
        "en": {"pin": "Pin", "dir": "Direction", "type": "Type", "label": "Label", "default": "Default",
               "in": "input", "out": "output", "example": "Example", "caps": "Capabilities", "flow": "Kind", "undo": "Undo",
               "danger": "Danger", "none": "none", "title": "Commands node reference", "state": "Changes state",
               "yes": "yes", "no": "no", "deferred": "This node is not available yet: its executor comes later."}}


def _cell(v):
    return str(v).replace("|", "\\|").replace("\n", " ") if v is not None else ""


def render_node(nd, lang="ru"):
    h = HEAD[lang]
    lines = ["### %s (`%s`)" % (nd.label(lang), nd.type_string), "", nd.description.get(lang, ""), ""]
    if nd.stage == "deferred":
        lines += ["> " + h["deferred"], ""]
    undo = nd.undo.get("default", "off") if nd.undo else h["none"]
    lines += ["- %s: %s" % (h["flow"], FLOW[lang][nd.flow]),
              "- %s: %s" % (h["caps"], ", ".join("`%s`" % c for c in nd.capabilities) or h["none"]),
              "- %s: %s" % (h["state"], h["yes"] if nd.changes_state else h["no"]),
              "- %s: %s" % (h["undo"], undo), "- %s: %s" % (h["danger"], nd.danger if nd.danger != "none" else h["none"]), ""]
    lines += ["| %s | %s | %s | %s | %s |" % (h["pin"], h["dir"], h["type"], h["label"], h["default"]), "|---|---|---|---|---|"]
    for direction, pins in (("in", nd.inputs), ("out", nd.outputs)):
        for p in pins:
            lines.append("| `%s` | %s | %s | %s | %s |" % (
                p.id, h[direction], T.type_name(p.type, lang), _cell(p.label.get(lang, "")),
                _cell(p.default) if p.has_default else ""))
    lines += ["", "**%s:** %s" % (h["example"], nd.example.get(lang, "")), ""]
    return "\n".join(lines)


def render_category(sch, cat, lang="ru"):
    nodes = sch.by_category().get(cat, [])
    return "## %s\n\n%s" % (CAT[lang].get(cat, cat), "\n".join(render_node(n, lang) for n in nodes))


def render_index(sch, lang="ru"):
    h = HEAD[lang]
    lines = ["# %s" % h["title"], ""]
    for cat, nodes in sch.by_category().items():
        lines.append("## %s" % CAT[lang].get(cat, cat))
        lines += ["- [%s](%s.md) — `%s`" % (n.label(lang), cat, n.type_string) for n in nodes]
        lines.append("")
    return "\n".join(lines)


def render_all(sch, lang="ru"):
    parts = [render_index(sch, lang)]
    parts += [render_category(sch, cat, lang) for cat in sch.by_category()]
    return "\n".join(parts) + "\n"


def write_docs(sch, lang, out):
    os.makedirs(out, exist_ok=True)
    files = {"index.md": render_index(sch, lang) + "\n"}
    for cat in sch.by_category():
        files["%s.md" % cat] = render_category(sch, cat, lang) + "\n"
    for name, text in files.items():
        with open(os.path.join(out, name), "w", encoding="utf-8") as f:
            f.write(text)
    return sorted(files)


# ---- the full documentation set (design §10): concept pages written by hand + reference and recipes generated -------------
CONCEPTS = ("getting-started", "events", "execution-order", "data-and-types", "variables", "loops", "functions", "debugging", "security")
UI = {"ru": {"concepts": "Понятия", "reference": "Справочник узлов", "recipes": "Рецепты", "docs": "Документация «Команд»",
             "recipes_intro": "Готовые команды из галереи примеров: что они делают и из каких шагов состоят.",
             "needs": "Нужны узлы, которых пока нет", "ready": "готова к запуску", "pending": "ждёт узлов",
             "caps": "Права", "pkgs": "Пакеты", "steps": "Шаги", "generated": "Файл создан автоматически из схемы узлов; не правьте его руками."},
      "en": {"concepts": "Concepts", "reference": "Node reference", "recipes": "Recipes", "docs": "Commands documentation",
             "recipes_intro": "Ready-made commands from the example gallery: what they do and what steps they consist of.",
             "needs": "Needs nodes that do not exist yet", "ready": "ready to run", "pending": "waiting for nodes",
             "caps": "Capabilities", "pkgs": "Packages", "steps": "Steps", "generated": "This file is generated from the node schema; do not edit it by hand."}}


def reference_schema(sch):
    """The built-in nodes only: the user's function library must not leak into the shipped reference."""
    from .schema import Schema
    r = Schema()
    r.nodes = sch.nodes
    return r


def concept_text(lang, cid):
    from .util import read_text
    p = os.path.join(paths.docs_src_dir(lang), cid + ".md")
    return read_text(p) if os.path.isfile(p) else ""


def title_of(text, fallback=""):
    for line in text.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return fallback


def reference_files(sch, lang):
    """{"reference/index.md": ..., "reference/<category>.md": ...}, from the schema only."""
    sch = reference_schema(sch)
    note = "<!-- %s -->\n\n" % UI[lang]["generated"]
    out = {"reference/index.md": note + render_index(sch, lang) + "\n"}
    for cat in sch.by_category():
        out["reference/%s.md" % cat] = note + render_category(sch, cat, lang) + "\n"
    return out


def recipes_text(lang, sch, gdir=None):
    from . import gallery
    from .util import read_json
    u = UI[lang]
    lines = ["# %s" % u["recipes"], "", u["recipes_intro"], ""]
    for f in gallery.files(gdir):
        e = gallery.entry_for(f, sch)
        cmd = read_json(f)
        lines += ["## %s" % gallery._pick(e["name"], lang), "", gallery._pick(e["description"], lang), "",
                  "- %s: %s" % (u["caps"], ", ".join("`%s`" % c for c in e["capabilities"]) or "-")]
        if e["packages"]:
            lines.append("- %s: %s" % (u["pkgs"], ", ".join("`%s`" % p for p in e["packages"])))
        lines.append("- %s" % (u["ready"] if e["ready"] else "%s: %s" % (u["pending"], ", ".join("`%s`" % m for m in e["missing"]))))
        steps = sorted(cmd.get("comments") or [], key=lambda c: (c.get("y", 0) > 200, c.get("x", 0), c.get("y", 0)))
        if steps:
            lines += ["", "**%s:**" % u["steps"], ""]
            lines += ["%d. **%s.** %s" % (i, gallery._pick(c.get("title"), lang), gallery._pick(c.get("text"), lang)) for i, c in enumerate(steps, 1)]
        lines.append("")
    return "\n".join(lines) + "\n"


def build_all(sch, lang, gdir=None):
    """Every file of the documentation as {relative path: text}: index, concepts, reference/, recipes.md."""
    u = UI[lang]
    out, toc = {}, ["# %s" % u["docs"], "", "## %s" % u["concepts"], ""]
    for cid in CONCEPTS:
        text = concept_text(lang, cid)
        out[cid + ".md"] = text
        toc.append("- [%s](%s.md)" % (title_of(text, cid), cid))
    toc += ["", "## %s" % u["reference"], "", "- [%s](reference/index.md)" % u["reference"], "", "## %s" % u["recipes"], "",
            "- [%s](recipes.md)" % u["recipes"], ""]
    out["index.md"] = "\n".join(toc)
    out.update(reference_files(sch, lang))
    out["recipes.md"] = recipes_text(lang, sch, gdir)
    return out


def write_all(sch, lang, out_dir, gdir=None):
    files = build_all(sch, lang, gdir)
    for rel, text in files.items():
        p = os.path.join(out_dir, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)
    return sorted(files)


def committed_reference_dir(lang):
    return os.path.join(paths.docs_src_dir(lang), "reference")


def write_reference(sch):
    """Refresh the committed reference (assets/custom-commands/docs/<lang>/reference/*.md)."""
    n = 0
    for lang in ("ru", "en"):
        d = committed_reference_dir(lang)
        os.makedirs(d, exist_ok=True)
        files = reference_files(sch, lang)
        for old in os.listdir(d):
            if old.endswith(".md") and "reference/" + old not in files:
                os.remove(os.path.join(d, old))
        for rel, text in files.items():
            with open(os.path.join(paths.docs_src_dir(lang), rel), "w", encoding="utf-8") as f:
                f.write(text)
            n += 1
    return n


def check(sch):
    """Documentation problems for doctor / CI: stale committed reference, missing concept pages, undocumented nodes."""
    from .util import read_text
    problems = []
    for lang in ("ru", "en"):
        for cid in CONCEPTS:
            if len(concept_text(lang, cid).strip()) < 80:
                problems.append("docs/%s/%s.md: missing or empty" % (lang, cid))
        want = reference_files(sch, lang)
        d = committed_reference_dir(lang)
        have = sorted("reference/" + f for f in os.listdir(d)) if os.path.isdir(d) else []
        for rel, text in want.items():
            p = os.path.join(paths.docs_src_dir(lang), rel)
            if not os.path.isfile(p) or read_text(p) != text:
                problems.append("docs/%s/%s: out of date (run: serpantinum-x cmd docs --write-reference)" % (lang, rel))
        for rel in have:
            if rel not in want:
                problems.append("docs/%s/%s: stale file" % (lang, rel))
        text = "\n".join(want.values())
        for nd in sch.nodes.values():
            if "`%s@%d`" % (nd.id, nd.version) not in text:
                problems.append("node %s is not in the %s reference" % (nd.id, lang))
    return problems


def pages(sch, lang):
    """The pages offered by the in-shell viewer: [{id, title, group}]."""
    from .util import read_text
    out = [{"id": "index", "title": UI[lang]["docs"], "group": "docs"}]
    for cid in CONCEPTS:
        out.append({"id": cid, "title": title_of(concept_text(lang, cid), cid), "group": "concepts"})
    for cat in reference_schema(sch).by_category():
        out.append({"id": "reference/" + cat, "title": CAT[lang].get(cat, cat), "group": "reference"})
    out.append({"id": "recipes", "title": UI[lang]["recipes"], "group": "recipes"})
    return out


def page(sch, lang, pid):
    return build_all(sch, lang).get(pid + ".md")
