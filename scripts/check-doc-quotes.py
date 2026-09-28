#!/usr/bin/env python3
import glob
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
QUOTE = re.compile(r'"([^"\n]{3,120})"\s*\((?:[a-z][^)\n]{2,80})\)')
LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
PIECE = re.compile(r"\bN\b|\d+|[·/…:]|\.\.\.")


def normalized(text):
    return text.replace("’", "'").replace("‑", "-").lower()


def app_text(root):
    literals = []
    for path in glob.glob(f"{root}/App/**/*.swift", recursive=True) + glob.glob(f"{root}/Sources/**/*.swift", recursive=True):
        with open(path, encoding="utf-8") as source:
            literals += LITERAL.findall(source.read())
    return normalized("\n".join(literals))


def stale_quotes(root):
    text = app_text(root)
    stale = []
    for path in sorted(glob.glob(f"{root}/docs/*.md")):
        with open(path, encoding="utf-8") as doc:
            for number, line in enumerate(doc, 1):
                for quote in QUOTE.findall(line):
                    pieces = [p.strip(" .,") for p in PIECE.split(quote)]
                    missing = [p for p in pieces if len(p) > 3 and normalized(p) not in text]
                    if missing:
                        stale.append(f"{path}:{number}: \"{quote}\" not in the app ({missing[0]!r})")
    return stale


if __name__ == "__main__":
    problems = stale_quotes(ROOT)
    for problem in problems:
        print(problem)
    if problems:
        print(f"{len(problems)} quoted message(s) in docs/ no longer match the app's wording")
    sys.exit(1 if problems else 0)
