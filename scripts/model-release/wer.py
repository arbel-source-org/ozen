#!/usr/bin/env python3
"""Word error rate of WhisperKit's report files against clips/refs.jsonl.

  wer.py <report-dir> [max-percent]

<report-dir> holds one <clip>.json per clip, as `whisperkit-cli transcribe
--report` writes them, or one <clip>.txt holding what the command printed. Prints each clip's words and the total, and exits
non-zero when the total is above max-percent (default 60): a model that
loads but talks nonsense must not reach a phone.
"""
import json
import re
import sys
import unicodedata
from pathlib import Path

NIKUD = re.compile(r"[֑-ׇ]")
PUNCT = re.compile(r"[^\w\s]|_", re.UNICODE)


def normalize(text: str) -> list[str]:
    text = unicodedata.normalize("NFC", text)
    text = NIKUD.sub("", text)
    text = text.replace("־", " ").replace("-", " ")
    return PUNCT.sub("", text).split()


def edit_distance(a: list[str], b: list[str]) -> int:
    previous = list(range(len(b) + 1))
    for i, word in enumerate(a, 1):
        current = [i]
        for j, other in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (word != other)))
        previous = current
    return previous[-1]


HEBREW = re.compile(r"[\u05d0-\u05ea]")


def report_text(report_dir: Path, clip: str) -> str:
    """The clip's transcript: WhisperKit's JSON report if there is one, else
    the last Hebrew line the command line printed for it."""
    stem = Path(clip).stem
    for candidate in (report_dir / f"{clip}.json", report_dir / f"{stem}.json"):
        if candidate.exists():
            data = json.loads(candidate.read_text())
            if isinstance(data, list):
                return " ".join(d.get("text", "") for d in data)
            return data.get("text", "")
    printed = report_dir / f"{stem}.txt"
    if printed.exists():
        lines = [l.strip() for l in printed.read_text().splitlines() if HEBREW.search(l)]
        return lines[-1] if lines else ""
    raise SystemExit(f"no report for {clip} in {report_dir}")


def main() -> None:
    report_dir = Path(sys.argv[1])
    limit = float(sys.argv[2]) if len(sys.argv) > 2 else 60.0
    refs = [json.loads(l) for l in (Path(__file__).parent / "clips" / "refs.jsonl").read_text().splitlines() if l.strip()]
    errors = words = 0
    for ref in refs:
        expected = normalize(ref["ref"])
        heard = normalize(report_text(report_dir, ref["file"]))
        distance = edit_distance(expected, heard)
        errors += distance
        words += len(expected)
        print(f"{ref['file']}: {distance}/{len(expected)} words wrong")
        print(f"  expected: {' '.join(expected)}")
        print(f"  heard:    {' '.join(heard)}")
    percent = 100 * errors / max(words, 1)
    print(f"total: {percent:.1f}% of {words} words wrong")
    if percent > limit:
        raise SystemExit(f"above the {limit:.0f}% limit")


if __name__ == "__main__":
    main()
