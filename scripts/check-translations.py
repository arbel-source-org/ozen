#!/usr/bin/env python3
r"""Checks every tr("hebrew", "english") call in the Swift sources, and the
translation table that stands in for Hebrew and English in every other
supported language.

Both strings must be plain literals, the English one must hold no Hebrew,
and both must interpolate exactly the same expressions. A templated call
(`tr("...", "...", args: [...])`) uses `%1`, `%2`... instead of `\(...)`;
both literals must use exactly the placeholders `1...N` for an N-element
args list. With --untranslated it also lists Hebrew string literals that
sit outside a tr call, so what is left to translate can be seen file by
file. Every run also checks Sources/OzenKit/Resources/Translations.json:
every language must have every English key, and a key with placeholders
must keep the same placeholder numbers in translation.
"""
import json
import re
import sys
from pathlib import Path

HEBREW = re.compile(r"[֐-׿]")
PLACEHOLDER = re.compile(r"%(\d+)")
ROOTS = ["App", "Sources"]
TRANSLATIONS_PATH = Path("Sources/OzenKit/Resources/Translations.json")
TRANSLATED_LANGUAGES = [
    "arabic", "russian", "amharic", "french", "spanish",
    "ukrainian", "german", "portuguese", "chineseSimplified", "hindi",
]


def literals(text):
    """Yields (start, end, body) for each single-line or multi-line Swift string literal."""
    i = 0
    n = len(text)
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j == -1 else j
            continue
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j == -1 else j + 2
            continue
        raw = 0
        k = i
        while k < n and text[k] == "#":
            raw += 1
            k += 1
        if k < n and text[k] == '"':
            triple = text.startswith('"""', k)
            quote = '"""' if triple else '"'
            j = k + len(quote)
            while j < n:
                if text[j] == "\\" and text.startswith("#" * raw, j + 1):
                    after = j + 1 + raw
                    if after < n and text[after] == "(":
                        level = 0
                        m = after
                        while m < n:
                            if text[m] == "(":
                                level += 1
                            elif text[m] == ")":
                                level -= 1
                                if level == 0:
                                    break
                            elif text[m] == '"':
                                inner = next(literals(text[m:]), None)
                                if inner:
                                    m += inner[1] - 1
                            m += 1
                        j = m + 1
                        continue
                    j = after + 1
                    continue
                if text.startswith(quote + "#" * raw, j):
                    end = j + len(quote) + raw
                    yield i, end, text[k + len(quote):j]
                    i = end
                    break
                if not triple and text[j] == "\n":
                    i = j
                    break
                j += 1
            else:
                return
            continue
        i += 1


def interpolations(body):
    found = []
    i = 0
    while True:
        i = body.find("\\(", i)
        if i == -1:
            return sorted(found)
        level = 0
        j = i + 1
        while j < len(body):
            if body[j] == "(":
                level += 1
            elif body[j] == ")":
                level -= 1
                if level == 0:
                    break
            j += 1
        found.append(re.sub(r"\s+", "", body[i + 2:j]))
        i = j


def placeholders(body):
    """The set of %N placeholder numbers used in a template string."""
    return {int(number) for number in PLACEHOLDER.findall(body)}


def unescape(body):
    """A Swift string literal's source text (as `literals()` yields it) still
    holds its escapes literally, e.g. a two-character `\\n` rather than a
    newline. `tr()` receives the runtime, already-unescaped string, so a key
    used to look it up in Translations.json must be unescaped the same way,
    or a key with an escape in it silently never matches."""
    out = []
    i = 0
    n = len(body)
    while i < n:
        c = body[i]
        if c == "\\" and i + 1 < n:
            nxt = body[i + 1]
            simple = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "'": "'", "\\": "\\", "0": "\0"}
            if nxt in simple:
                out.append(simple[nxt])
                i += 2
                continue
            if nxt == "u" and i + 2 < n and body[i + 2] == "{":
                end = body.find("}", i + 3)
                if end != -1:
                    out.append(chr(int(body[i + 3:end], 16)))
                    i = end + 1
                    continue
            out.append(nxt)
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def args_list(rest, after):
    """rest[after:] optionally holds `, args: [ ... ]`. Returns the number
    of string-literal elements in that list, or None when there's no args
    list right after the two template literals."""
    i = after
    n = len(rest)
    while i < n and rest[i] in " \t\n":
        i += 1
    if i >= n or rest[i] != ",":
        return None
    i += 1
    while i < n and rest[i] in " \t\n":
        i += 1
    if not rest.startswith("args", i):
        return None
    i += len("args")
    while i < n and rest[i] in " \t\n":
        i += 1
    if i >= n or rest[i] != ":":
        return None
    i += 1
    while i < n and rest[i] in " \t\n":
        i += 1
    if i >= n or rest[i] != "[":
        return None
    depth = 0
    j = i
    while j < n:
        if rest[j] == "[":
            depth += 1
        elif rest[j] == "]":
            depth -= 1
            if depth == 0:
                break
        elif rest[j] == '"':
            inner = next(literals(rest[j:]), None)
            if inner:
                j += inner[1] - 1
        j += 1
    return len(list(literals(rest[i:j + 1])))


def check(path, list_untranslated, keys):
    text = path.read_text(encoding="utf-8")
    problems = []
    inside_tr = set()
    for match in re.finditer(r"\btr\(", text):
        rest = text[match.end():]
        found = list(literals(rest))
        if len(found) < 2 or found[0][0] != len(rest) - len(rest.lstrip()):
            line = text.count("\n", 0, match.start()) + 1
            problems.append(f"{path}:{line}: tr( is not followed by two string literals")
            continue
        (s1, e1, hebrew), (s2, e2, english) = found[0], found[1]
        between = rest[e1:s2]
        line = text.count("\n", 0, match.start()) + 1
        if between.strip() != ",":
            problems.append(f"{path}:{line}: tr( arguments must be two literals separated by a comma")
            continue
        inside_tr.add(match.end() + s1)
        if HEBREW.search(english):
            problems.append(f"{path}:{line}: English text contains Hebrew: {english[:60]}")
        if interpolations(hebrew) != interpolations(english):
            problems.append(f"{path}:{line}: interpolations differ: {interpolations(hebrew)} vs {interpolations(english)}")
        if not english.strip() and hebrew.strip():
            problems.append(f"{path}:{line}: English text is empty")
        count = args_list(rest, e2)
        heb_placeholders = placeholders(hebrew)
        eng_placeholders = placeholders(english)
        if count is None:
            if heb_placeholders or eng_placeholders:
                problems.append(f"{path}:{line}: template placeholders %N with no args: list")
        else:
            expected = set(range(1, count + 1))
            if heb_placeholders != expected or eng_placeholders != expected:
                problems.append(
                    f"{path}:{line}: placeholders must be exactly %1..%{count}: "
                    f"Hebrew has {sorted(heb_placeholders)}, English has {sorted(eng_placeholders)}"
                )
        keys.setdefault(unescape(english), set()).update(range(1, (count or 0) + 1))
    untranslated = []
    if list_untranslated:
        for start, _, body in literals(text):
            if HEBREW.search(body) and start not in inside_tr:
                untranslated.append(text.count("\n", 0, start) + 1)
    return problems, untranslated


def check_translation_table(keys):
    """Every English key from every tr() call must have an entry in every
    other language, with the placeholder numbers it was built with."""
    problems = []
    if not TRANSLATIONS_PATH.exists():
        return [f"{TRANSLATIONS_PATH}: missing"]
    try:
        table = json.loads(TRANSLATIONS_PATH.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        return [f"{TRANSLATIONS_PATH}: invalid JSON: {error}"]
    for language in TRANSLATED_LANGUAGES:
        entries = table.get(language)
        if entries is None:
            problems.append(f"{TRANSLATIONS_PATH}: missing language {language!r}")
            continue
        missing = sorted(key for key in keys if key not in entries)
        if missing:
            shown = ", ".join(repr(key[:40]) for key in missing[:8])
            problems.append(f"{TRANSLATIONS_PATH}: {language} is missing {len(missing)} keys ({shown}{' ...' if len(missing) > 8 else ''})")
        for key, expected_numbers in keys.items():
            translation = entries.get(key)
            if translation is None:
                continue
            if not translation.strip():
                problems.append(f"{TRANSLATIONS_PATH}: {language}[{key[:40]!r}] is empty")
                continue
            found_numbers = placeholders(translation)
            if found_numbers != expected_numbers:
                problems.append(
                    f"{TRANSLATIONS_PATH}: {language}[{key[:40]!r}] placeholders {sorted(found_numbers)} "
                    f"don't match the source's {sorted(expected_numbers)}"
                )
    return problems


SYSTEM_STRING_FILES = ["App/Ozen/OzenIntents.swift", "App/Shared/StartCaptionsIntent.swift", "App/OzenWidget/OzenWidgetBundle.swift"]
SYSTEM_CATALOG = Path("App/Shared/Localizable.xcstrings")
SYSTEM_LANGUAGES = ["en", "ar", "ru", "am", "fr", "es", "uk", "de", "pt-PT", "zh-Hans", "hi"]
SYSTEM_STRING = re.compile(r'(?:LocalizedStringResource = |IntentDescription\(|@Parameter\(title: |Summary\(|shortTitle: |\.displayName\(|\.description\(|Label\()"([^"]*[\u0590-\u05FF][^"]*)"')


def check_system_strings():
    """Texts iOS itself shows (Siri and Shortcuts, the Control Center button)
    are translated by Apple's string catalog in the phone's language, not by
    tr(): each Hebrew one needs an entry there in every language."""
    catalog = json.loads(SYSTEM_CATALOG.read_text(encoding="utf-8"))["strings"]
    problems = []
    for name in SYSTEM_STRING_FILES:
        for number, line in enumerate(Path(name).read_text(encoding="utf-8").splitlines(), 1):
            for text in SYSTEM_STRING.findall(line):
                key = re.sub(r"\\\(\\\.\$(\w+)\)", r"${\1}", text)
                missing = [l for l in SYSTEM_LANGUAGES if l not in catalog.get(key, {}).get("localizations", {})]
                if missing:
                    problems.append(f"{name}:{number}: {key!r} missing from {SYSTEM_CATALOG} in {', '.join(missing)}")
    return problems


def check_permission_prompts():
    """iOS's own permission prompts and the languages the app declares:
    each *UsageDescription in project.yml needs every language in
    App/Ozen/InfoPlist.xcstrings, and every declared bundle localization
    list must name all the languages the catalogs carry, or iOS ignores
    those translations."""
    project = Path("project.yml").read_text(encoding="utf-8")
    catalog = json.loads(Path("App/Ozen/InfoPlist.xcstrings").read_text(encoding="utf-8"))["strings"]
    problems = []
    for key in sorted(set(re.findall(r"^\s+(NS\w+UsageDescription):", project, re.MULTILINE))):
        missing = [l for l in ["he"] + SYSTEM_LANGUAGES if l not in catalog.get(key, {}).get("localizations", {})]
        if missing:
            problems.append(f"App/Ozen/InfoPlist.xcstrings: {key} missing in {', '.join(missing)}")
    for declared in re.findall(r"CFBundleLocalizations: \[([^\]]*)\]", project):
        missing = set(["he"] + SYSTEM_LANGUAGES) - {l.strip() for l in declared.split(",")}
        if missing:
            problems.append(f"project.yml: CFBundleLocalizations lacks {', '.join(sorted(missing))}")
    return problems


def main():
    list_untranslated = "--untranslated" in sys.argv
    skip_table = "--no-table" in sys.argv
    paths = [a for a in sys.argv[1:] if not a.startswith("--")]
    requested = {Path(p) for p in paths}
    all_files = [p for root in ROOTS for p in Path(root).rglob("*.swift") if p.name != "Localization.swift"]
    # The translation table is checked against every tr() call in the whole
    # tree, even when explicit paths narrow which files get a per-line report.
    all_problems = []
    keys = {}
    for path in sorted(all_files):
        problems, untranslated = check(path, list_untranslated, keys)
        if not requested or path in requested:
            all_problems += problems
            if untranslated:
                print(f"{path}: {len(untranslated)} Hebrew literals outside tr (lines {', '.join(map(str, untranslated[:12]))}{' ...' if len(untranslated) > 12 else ''})")
    if not skip_table:
        all_problems += check_translation_table(keys)
        all_problems += check_system_strings()
        all_problems += check_permission_prompts()
    for problem in all_problems:
        print(problem)
    sys.exit(1 if all_problems else 0)


if __name__ == "__main__":
    main()
