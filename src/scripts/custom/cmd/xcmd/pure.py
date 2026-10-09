"""Pure data nodes (logic helpers): compare, boolean, text, math and list nodes. Every function takes the node inputs
(already typed by the engine) and returns the output pins; failures are NodeError with a Russian message."""
import re

from .errors import NodeError
from .executors import to_text

FUNCS = {}


def reg(name):
    def deco(fn):
        FUNCS[name] = fn
        return fn
    return deco


@reg("compare_number")
def compare_number(i):
    a, b, op = i["a"], i["b"], i["op"]
    return {"result": {"==": a == b, "!=": a != b, "<": a < b, "<=": a <= b, ">": a > b, ">=": a >= b}[op]}


@reg("compare_text")
def compare_text(i):
    a, b, op = str(i["a"] or ""), str(i["b"] or ""), i["op"]
    if i.get("ignore_case", True) and op != "regex":
        a, b = a.lower(), b.lower()
    if op == "regex":
        try:
            return {"result": re.search(b, a, re.I if i.get("ignore_case", True) else 0) is not None}
        except re.error as e:
            raise NodeError("Выражение «%s» записано неверно: %s" % (b[:60], e))
    return {"result": {"equals": a == b, "not_equals": a != b, "contains": b in a, "starts_with": a.startswith(b),
                       "ends_with": a.endswith(b)}[op]}


@reg("and")
def and_(i):
    return {"result": bool(i["a"]) and bool(i["b"])}


@reg("or")
def or_(i):
    return {"result": bool(i["a"]) or bool(i["b"])}


@reg("not")
def not_(i):
    return {"result": not i["value"]}


@reg("concat")
def concat(i):
    return {"text": to_text(i["a"]) + to_text(i["b"])}


@reg("format")
def format_(i):
    out = str(i["template"] or "")
    for k in ("a", "b", "c"):
        out = out.replace("{%s}" % k, to_text(i.get(k)))
    return {"text": out}


@reg("split")
def split(i):
    text, sep = str(i["text"] or ""), i["sep"] if i["sep"] is not None else ","
    if text == "":
        return {"list": []}
    return {"list": text.split(sep) if sep != "" else list(text)}


@reg("join")
def join(i):
    lst = i["list"]
    if not isinstance(lst, list):
        raise NodeError("Для «Склеить список» нужен список")
    return {"text": (i["sep"] if i["sep"] is not None else ", ").join(to_text(v) for v in lst)}


@reg("math")
def math(i):
    a, b, op = i["a"], i["b"], i["op"]
    if op in ("/", "%") and b == 0:
        raise NodeError("Деление на ноль: второе число равно 0")
    r = {"+": lambda: a + b, "-": lambda: a - b, "*": lambda: a * b, "/": lambda: a / b, "%": lambda: a % b,
         "min": lambda: min(a, b), "max": lambda: max(a, b)}[op]()
    r = float(r)
    if r != r or r in (float("inf"), float("-inf")):
        raise NodeError("Результат вычисления не число")
    return {"result": r, "whole": int(r // 1)}


@reg("list_length")
def list_length(i):
    if not isinstance(i["list"], list):
        raise NodeError("Для «Длина списка» нужен список")
    return {"length": len(i["list"])}


@reg("list_get")
def list_get(i):
    lst, idx = i["list"], i["index"]
    if not isinstance(lst, list):
        raise NodeError("Для «Элемент списка» нужен список")
    if not 0 <= idx < len(lst):
        raise NodeError("В списке из %d элементов нет номера %d (нумерация с нуля)" % (len(lst), idx))
    return {"item": lst[idx]}


@reg("range")
def range_(i):
    return {"list": list(range(i["start"], i["start"] + max(0, min(i["count"], 1000))))}


KINDS = {
    "image": {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".tif", ".tiff", ".svg", ".avif", ".heic", ".ico", ".raw", ".cr2", ".nef"},
    "document": {".pdf", ".doc", ".docx", ".odt", ".rtf", ".txt", ".md", ".xls", ".xlsx", ".ods", ".csv", ".ppt", ".pptx", ".odp", ".epub", ".djvu", ".fb2", ".tex"},
    "archive": {".zip", ".tar", ".gz", ".tgz", ".bz2", ".xz", ".zst", ".7z", ".rar", ".iso", ".deb", ".rpm", ".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst"},
    "video": {".mp4", ".mkv", ".webm", ".avi", ".mov", ".wmv", ".flv", ".m4v", ".mpg", ".mpeg", ".ts"},
    "audio": {".mp3", ".flac", ".ogg", ".opus", ".wav", ".m4a", ".aac", ".wma", ".aiff"},
}


@reg("file_kind")
def file_kind(i):
    import mimetypes
    path = str(i["path"] or "").strip()
    name = path.rsplit("/", 1)[-1].lower()
    ext = ("." + name.rsplit(".", 1)[1]) if "." in name.strip(".") else ""
    if name.endswith((".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst")):
        ext = ".tar" + ext
    mime = mimetypes.guess_type(name)[0] or ""
    kind = next((k for k, exts in KINDS.items() if ext in exts), None)
    if kind is None and mime:                                  # unknown extension: fall back to the MIME family
        kind = {"image": "image", "video": "video", "audio": "audio"}.get(mime.split("/")[0])
        kind = kind or ("document" if mime.startswith("text/") or mime in ("application/pdf",) else None)
    return {"kind": kind or "other", "ext": ext.lstrip("."), "mime": mime}
