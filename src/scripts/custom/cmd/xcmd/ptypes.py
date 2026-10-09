"""Pin type system: strict, only int->float and T->any are implicit (design §4)."""
import re

BASE = ("exec", "bool", "int", "float", "text", "color", "time", "duration", "path", "url", "device", "json", "any")

NAMES_RU = {"exec": "порядок выполнения", "bool": "да/нет", "int": "число", "float": "дробное число", "text": "текст",
            "color": "цвет", "time": "время", "duration": "длительность", "path": "путь", "url": "ссылка",
            "device": "устройство", "json": "данные", "any": "любое значение", "list": "список"}
NAMES_EN = {"exec": "execution", "bool": "yes/no", "int": "number", "float": "decimal number", "text": "text",
            "color": "color", "time": "time", "duration": "duration", "path": "path", "url": "link",
            "device": "device", "json": "data", "any": "any value", "list": "list"}

_LIST = re.compile(r"^list<(.+)>$")
_TIME = re.compile(r"^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$")
_COLOR = re.compile(r"^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$")


def is_list(t):
    return bool(_LIST.match(t))


def list_inner(t):
    m = _LIST.match(t)
    return m.group(1) if m else None


def valid_type(t, generics=()):
    if t in BASE or t in generics:
        return True
    inner = list_inner(t)
    return inner is not None and valid_type(inner, generics)


def type_name(t, lang="ru"):
    names = NAMES_RU if lang == "ru" else NAMES_EN
    inner = list_inner(t)
    if inner is not None:
        return ("список (%s)" if lang == "ru" else "list (%s)") % type_name(inner, lang)
    return names.get(t, t)


def compatible(src, dst):
    """May a value of type `src` flow into an input of type `dst`?"""
    if src == "exec" or dst == "exec":
        return src == dst
    if src == dst or dst == "any":
        return True
    if src == "int" and dst == "float":
        return True
    ls, ld = list_inner(src), list_inner(dst)
    if ls is not None and ld is not None:
        return ld == "any" or ls == ld
    return False


def substitute(t, bindings):
    inner = list_inner(t)
    if inner is not None:
        return "list<%s>" % substitute(inner, bindings)
    return bindings.get(t, t)


def unify(pattern, concrete, bindings, generics):
    """Bind generic names of `pattern` against `concrete`. Returns False on conflict."""
    if pattern in generics:
        cur = bindings.get(pattern)
        if cur is None or cur == "any":
            bindings[pattern] = concrete
            return True
        return cur == concrete or compatible(concrete, cur)
    pi, ci = list_inner(pattern), list_inner(concrete)
    if pi is not None:
        if ci is None:
            return False
        return unify(pi, ci, bindings, generics)
    return compatible(concrete, pattern)


def infer_literal(value):
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, int):
        return "int"
    if isinstance(value, float):
        return "float"
    if isinstance(value, str):
        return "text"
    if isinstance(value, list):
        if not value:
            return "list<any>"
        kinds = {infer_literal(v) for v in value}
        if kinds == {"int", "float"}:
            return "list<float>"
        return "list<%s>" % kinds.pop() if len(kinds) == 1 else None
    if isinstance(value, dict):
        return "json"
    return None


def check_literal(t, value):
    """None when `value` is a valid literal of type `t`, else a short reason (ru)."""
    if t == "any":
        return None
    if t == "bool":
        return None if isinstance(value, bool) else "ожидалось «да/нет»"
    if t == "int":
        return None if isinstance(value, int) and not isinstance(value, bool) else "ожидалось целое число"
    if t in ("float", "duration"):
        return None if isinstance(value, (int, float)) and not isinstance(value, bool) else "ожидалось число"
    if t in ("text", "path", "url", "device"):
        return None if isinstance(value, str) else "ожидался текст"
    if t == "color":
        return None if isinstance(value, str) and _COLOR.match(value) else "ожидался цвет вида #RRGGBB"
    if t == "time":
        return None if isinstance(value, str) and _TIME.match(value) else "ожидалось время вида ЧЧ:ММ"
    if t == "json":
        return None if isinstance(value, (dict, list, str, int, float, bool)) or value is None else "ожидались данные JSON"
    inner = list_inner(t)
    if inner is not None:
        if not isinstance(value, list):
            return "ожидался список"
        for i, v in enumerate(value):
            err = check_literal(inner, v)
            if err:
                return "элемент %d: %s" % (i + 1, err)
        return None
    return "неизвестный тип"


def default_value(t):
    return {"bool": False, "int": 0, "float": 0.0, "text": "", "duration": 0.0, "json": None}.get(
        t, [] if is_list(t) else "")
