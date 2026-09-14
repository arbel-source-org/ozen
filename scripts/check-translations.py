#!/usr/bin/env python3
"""Checks every tr("hebrew", "english") call in the Swift sources.

Both strings must be plain literals, the English one must hold no Hebrew,
and both must interpolate exactly the same expressions. With --untranslated
it also lists Hebrew string literals that sit outside a tr call, so what
is left to translate can be seen file by file.
"""
import re
import sys
from pathlib import Path

HEBREW = re.compile(r"[֐-׿]")
ROOTS = ["App", "Sources"]


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
            depth = 0
            while j < n:
                if text[j] == "\\" and text.startswith("#" * raw, j + 1):
                    after = j + 1 + raw
                    if after < n and text[after] == "(":
                        depth_start = after
                        level = 0
                        m = depth_start
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


def check(path, list_untranslated):
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
    untranslated = []
    if list_untranslated:
        for start, _, body in literals(text):
            if HEBREW.search(body) and start not in inside_tr:
                untranslated.append(text.count("\n", 0, start) + 1)
    return problems, untranslated


def main():
    list_untranslated = "--untranslated" in sys.argv
    paths = [a for a in sys.argv[1:] if not a.startswith("--")]
    files = [Path(p) for p in paths] or [p for root in ROOTS for p in Path(root).rglob("*.swift") if p.name != "Localization.swift"]
    all_problems = []
    for path in sorted(files):
        problems, untranslated = check(path, list_untranslated)
        all_problems += problems
        if untranslated:
            print(f"{path}: {len(untranslated)} Hebrew literals outside tr (lines {', '.join(map(str, untranslated[:12]))}{' ...' if len(untranslated) > 12 else ''})")
    for problem in all_problems:
        print(problem)
    sys.exit(1 if all_problems else 0)


if __name__ == "__main__":
    main()
