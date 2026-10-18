#!/usr/bin/env python3
"""Fail if anything that must not be published is reachable from the given refs.

Checks every commit reachable from the refs (default: HEAD):
  * author and committer are exactly the expected identity
  * no blob path matches a forbidden pattern (raw device logs, VM images, binaries)
  * no blob content contains secret-like or machine-identifying material

Usage: python3 scripts/check-public-history.py [--repo PATH] [REF ...]
Prints numbered progress and a summary; exits 1 on any finding.
"""
import argparse
import re
import subprocess
import sys
import time

IDENTITY = "Himansh Raj <iamthehimansh@gmail.com>"

FORBIDDEN_PATHS = [
    re.compile(r"(^|/)research/stealth/results/"),
    re.compile(r"(^|/)\.cocreate/"),
    re.compile(r"\.(img|qcow2|apk|so|pyc|dmg|zip|bundle)$"),
    re.compile(r"(^|/)__pycache__/"),
    re.compile(r"(^|/)REPORT\.md$"),
    re.compile(r"(^|/)\.env"),
]

FORBIDDEN_CONTENT = [
    (re.compile(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "private key"),
    (re.compile(rb"QAAAA[A-Za-z0-9+/]{200,}"), "ADB public key"),
    (re.compile(rb"ghp_[A-Za-z0-9]{20,}"), "GitHub token"),
    (re.compile(rb"AKIA[A-Z0-9]{16}"), "AWS key"),
    (re.compile(rb"sk-[A-Za-z0-9]{20,}"), "API key"),
    (re.compile(b"Himanshs-" + b"MacBook-Pro"), "machine hostname"),
    (re.compile(b"/Users/" + b"iamthehimansh"), "local home path"),
    (re.compile(b"kestrel-" + b"stealth"), "other worktree reference"),
]


def log(message):
    print(time.strftime("[%H:%M:%S]"), message, flush=True)


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True).stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".")
    parser.add_argument("refs", nargs="*", default=["HEAD"])
    args = parser.parse_args()
    problems = []

    log("[1/3] Checking commit identities")
    lines = git(args.repo, "log", "--format=%H%x00%an <%ae>%x00%cn <%ce>", *args.refs).decode().splitlines()
    for line in lines:
        sha, author, committer = line.split("\0")
        if author != IDENTITY or committer != IDENTITY:
            problems.append(f"{sha[:10]} identity author={author!r} committer={committer!r}")
    log(f"[1/3] {len(lines)} commits checked")

    log("[2/3] Checking every reachable path")
    blobs = {}
    tree_entries = 0
    for commit in lines:
        sha = commit.split("\0", 1)[0]
        entries = git(args.repo, "ls-tree", "-r", "-z", sha).split(b"\0")
        for entry in entries:
            if not entry:
                continue
            metadata, raw_path = entry.split(b"\t", 1)
            _, kind, object_id = metadata.decode().split()
            path = raw_path.decode("utf-8", errors="strict")
            tree_entries += 1
            for pattern in FORBIDDEN_PATHS:
                if pattern.search(path):
                    problems.append(f"forbidden path {path}")
            if kind == "blob":
                blobs.setdefault(object_id, path)
            else:
                problems.append(f"unreviewed {kind} at {path}")
    log(f"[2/3] {tree_entries} historical path entries, {len(blobs)} unique blobs checked")

    log("[3/3] Scanning blob contents")
    batch = subprocess.run(["git", "-C", args.repo, "cat-file", "--batch-check"],
                           input="\n".join(blobs).encode(), capture_output=True, check=True).stdout.decode()
    scanned = 0
    for row in batch.splitlines():
        sha, kind, size = row.split()[:3]
        if kind != "blob":
            problems.append(f"unexpected object type {kind}: {sha}")
            continue
        if int(size) > 5_000_000:
            problems.append(f"unscanned large blob in {blobs[sha]}")
            continue
        data = git(args.repo, "cat-file", "-p", sha)
        scanned += 1
        for pattern, label in FORBIDDEN_CONTENT:
            if pattern.search(data):
                problems.append(f"{label} in {blobs[sha]}")
        if scanned % 200 == 0:
            log(f"[3/3] {scanned} blobs scanned")
    log(f"[3/3] {scanned} blobs scanned")

    for problem in sorted(set(problems)):
        print("FAIL:", problem)
    log(f"SUMMARY: {len(set(problems))} problem(s) across {len(lines)} commits")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
