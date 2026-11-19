"""Checks the workflows for the two rules from the security review (standard library only).

    python3 .github/scripts/check_workflows.py [.github/workflows/*.yml]

1. Every action from another repository is pinned to a full commit SHA (`owner/repo@<40 hex>`),
   so nobody who can move a tag upstream changes what runs here (F3).
2. A job that may mint an OIDC token (`id-token: write`, which can assume the deploy role) runs
   no downloaded code: no pip installs, no `| sh`, no Python, no loading of drivers (F2).
"""

from __future__ import annotations

import glob
import re
import sys

PINNED = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$")
USES = re.compile(r"^\s*(?:-\s+)?uses:\s*([^\s#]+)")
JOB = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$")
# What a credentialed job must not do.
FORBIDDEN = [
    (re.compile(r"\bpip3?\b|\buv\b"), "installs packages"),
    (re.compile(r"\|\s*(sudo\s+)?(ba|da)?sh\b"), "pipes something into a shell"),
    (re.compile(r"\bpython3?\b"), "runs Python"),
    (re.compile(r"check_driver_by_name|\biex\b|Invoke-Expression"), "runs downloaded code"),
]


def jobs_of(lines: list[str]) -> dict[str, list[str]]:
    jobs: dict[str, list[str]] = {}
    current = None
    in_jobs = False
    for line in lines:
        if re.match(pattern=r"^jobs:\s*$", string=line):
            in_jobs = True
            continue
        if in_jobs and re.match(pattern=r"^\S", string=line):
            in_jobs = False
            current = None
        if in_jobs:
            m = JOB.match(line)
            if m:
                current = m.group(1)
                jobs[current] = []
                continue
            if current is not None:
                jobs[current].append(line)
    return jobs


def main() -> int:
    files = sys.argv[1:] or sorted(glob.glob(pathname=".github/workflows/*.yml"))
    problems = []
    for path in files:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
        for number, line in enumerate(lines, start=1):
            m = USES.match(line)
            if m and not m.group(1).startswith("./") and not PINNED.match(m.group(1)):
                problems.append(f"{path}:{number}: {m.group(1)} is not pinned to a full commit SHA")
        for job, body in jobs_of(lines=lines).items():
            if not any(re.search(pattern=r"\bid-token:\s*write\b", string=line) for line in body):
                continue
            for line in body:
                code = line.split(" #", 1)[0]
                if code.lstrip().startswith("#"):
                    continue
                for pattern, what in FORBIDDEN:
                    if pattern.search(code):
                        problems.append(f"{path}: job '{job}' has id-token: write and {what}: {line.strip()}")
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        return 1
    print(f"workflows OK: {len(files)} files, every action pinned, no credentialed job runs downloaded code")
    return 0


if __name__ == "__main__":
    sys.exit(main())
