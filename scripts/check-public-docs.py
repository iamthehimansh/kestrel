#!/usr/bin/env python3
"""Check that the public documentation set exists, links resolve and required sections are present.

Usage: python3 scripts/check-public-docs.py   (exits 1 on any problem)
"""
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

REQUIRED = {
    "README.md": ["Download", "Features", "Requirements", "Build from source", "Contributing", "Credits", "License"],
    "CONTRIBUTING.md": [],
    "CODE_OF_CONDUCT.md": [],
    "SECURITY.md": [],
    "CHANGELOG.md": [],
    "THIRD_PARTY_NOTICES.md": [],
    "docs/guide/getting-started.md": [],
    "docs/guide/user-guide.md": [],
    "docs/guide/architecture.md": [],
    "docs/guide/building.md": [],
    "docs/guide/compatibility.md": [],
    "docs/research/README.md": [],
    "docs/research/experiment-ledger.md": [],
    "docs/research/bgmi-case-study.md": [],
    "docs/research/audio-case-study.md": [],
    "docs/research/detection-surface.md": [],
}

FORBIDDEN = [
    (re.compile("/Users/" + "iamthehimansh"), "local home path"),
    (re.compile("kestrel-" + "stealth"), "other worktree reference"),
    (re.compile(r"\bundetectable\b", re.I), "undetectability claim"),
    (re.compile(r"guaranteed? (to )?trend", re.I), "trending promise"),
]

LINK = re.compile(r"\[[^\]]*\]\(([^)#\s]+)(#[^)]*)?\)")


def log(message):
    print(time.strftime("[%H:%M:%S]"), message, flush=True)


def main():
    problems = []
    log(f"[1/3] Checking {len(REQUIRED)} required documents and sections")
    for name, sections in REQUIRED.items():
        path = ROOT / name
        if not path.exists():
            problems.append(f"missing {name}")
            continue
        text = path.read_text()
        for section in sections:
            if not re.search(r"^#+ .*" + re.escape(section), text, re.M):
                problems.append(f"{name}: missing section '{section}'")

    docs = [ROOT / "README.md", ROOT / "CONTRIBUTING.md", *ROOT.glob("docs/**/*.md")]
    log(f"[2/3] Checking relative links in {len(docs)} files")
    for doc in docs:
        if not doc.exists():
            continue
        for target, _ in LINK.findall(doc.read_text()):
            if re.match(r"[a-z]+:", target):
                continue
            if not (doc.parent / target).exists():
                problems.append(f"{doc.relative_to(ROOT)}: broken link {target}")

    log("[3/3] Scanning for private paths and overclaims")
    for doc in docs:
        if not doc.exists():
            continue
        for pattern, label in FORBIDDEN:
            for match in pattern.finditer(doc.read_text()):
                line = doc.read_text()[:match.start()].count("\n") + 1
                if label == "undetectability claim" and "research" in str(doc):
                    context = doc.read_text().splitlines()[line - 1].lower()
                    if any(word in context for word in ("not ", "no ", "does not", "cannot", "never")):
                        continue
                problems.append(f"{doc.relative_to(ROOT)}:{line}: {label}")

    for problem in problems:
        print("FAIL:", problem)
    log(f"SUMMARY: {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
