"""Local pre-flight for the homelab-pve workflows and composite actions.

1. parse every workflow and composite action as YAML
2. pull every `run:` block out and hand it to bash -n
3. reject `${{ ... }}` shapes GitHub cannot parse
4. reject context lookups a composite action is not allowed to make

Each of those is a failure mode that costs a real run otherwise, and two of
them (3 and 4) only surface at dispatch or at template-validation time --
neither shows up as a failed push.

Every `run:` block goes through a FILE here, never `bash -c <string>`: MSYS2
silently truncates a long `-c` argument, and the symptom is a heredoc that
stops mid-line with no error at all. See the note in gencheck.py.

Kept importable (main() + __main__ guard) so the rules can be unit-tested
against the exact text that broke a real run.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

# Repo root: CI runs from a checkout, local runs from the absolute path below.
# REPO_ROOT wins when it is set.
REPO = Path(os.environ.get("REPO_ROOT")
            or r"C:\Users\JackPeng\devops\github\homelab-pve")
WF_DIR = REPO / ".github" / "workflows"
ACTION_DIRS = [REPO / ".github" / "actions", REPO / "pipeline-template" / "actions"]
# Prefer whatever bash is on PATH; CI runs in a Debian slim image, the local
# runs found Git for Windows' bash by absolute path. bin\, not usr\bin\ -- see
# the note in gencheck.py: only the launcher puts its own /usr/bin on PATH.
_WINDOWS_BASH = (
    r"C:\Program Files\Git\bin\bash.exe",
    r"D:\Program Files\Git\bin\bash.exe",
    r"D:\bin\PortableGit\bin\bash.exe",
)
BASH = (os.environ.get("BASH") or shutil.which("bash")
        or next((p for p in _WINDOWS_BASH if os.path.exists(p)),
                _WINDOWS_BASH[0]))

# A `${{ ... }}` expression GitHub cannot parse fails the DISPATCH, not the
# push: "HTTP 422 Invalid Argument - failed to parse workflow". The usual
# cause is a code generator that emitted f-string escaping literally, so
# `${{{{ x }}}}` lands in the file as four braces and GitHub reads the
# expression as `{ x` -> "Unexpected symbol: '{{'".
BAD_BRACES = re.compile(r"\{\{\{|\}\}\}")

# An action.yml manifest is parsed in a restricted template context that has no
# `secrets` (and no guarantee of `env`). A run then dies before the first step
# with "Unrecognized named-value: 'secrets'". Nothing else catches that, so
# catch it here: inside a composite action everything must come in as `inputs`.
BANNED_IN_ACTION = re.compile(
    r"\$\{\{\s*(secrets|env|vars|github|steps|needs|strategy|matrix)\."
)


class Report:
    def __init__(self):
        self.rc = 0
        self.scripts = 0

    def fail(self, *lines):
        self.rc = 1
        for line in lines:
            print(line)


def check_expression_shapes(text, label, rep):
    for lineno, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue  # a comment explaining a rule is not a use of it
        if BAD_BRACES.search(line):
            rep.fail(
                f"  EXPR FAIL {label} line {lineno}: quadruple braces",
                f"           {line.strip()}",
                f"           a generator leaked f-string escaping: it needs"
                f" quadruple braces in the generator and double in the file",
            )


def check_action_contexts(text, label, rep):
    for lineno, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        for m in BANNED_IN_ACTION.finditer(line):
            rep.fail(
                f"  CTX FAIL {label} line {lineno}: composite actions only get"
                f" 'inputs', found {m.group(1)}.*",
                f"           {line.strip()}",
                f"           pass it in from the workflow with `with:` instead",
            )


def check_run(label, run, rep):
    with tempfile.NamedTemporaryFile(
        "w", suffix=".sh", encoding="utf-8", newline="\n", delete=False
    ) as fh:
        fh.write(run)
        path = fh.name
    proc = subprocess.run([BASH, "-n", path], capture_output=True, text=True)
    rep.scripts += 1
    if proc.returncode != 0:
        rep.fail(f"  SH FAIL  {label}")
        for line in (proc.stderr or "").splitlines()[:6]:
            print(f"           {line}")


def check_workflows(rep):
    for wf in sorted(WF_DIR.glob("*.y*ml")):
        text = wf.read_text(encoding="utf-8")
        check_expression_shapes(text, wf.name, rep)
        try:
            doc = yaml.safe_load(text)
        except Exception as exc:
            rep.fail(f"YAML FAIL  {wf.name}: {exc}")
            continue

        print(f"YAML ok    {wf.name}")
        if not isinstance(doc, dict):
            continue

        for job_name, job in (doc.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            for step in job.get("steps") or []:
                if not isinstance(step, dict):
                    continue
                run = step.get("run")
                if not isinstance(run, str):
                    continue
                check_run(f"{wf.name}::{job_name}::{step.get('name','<unnamed>')}",
                          run, rep)


def check_actions(rep):
    acts = set()
    for base in ACTION_DIRS:
        if base.is_dir():
            acts.update(base.rglob("action.yml"))

    for act in sorted(acts):
        rel = act.relative_to(REPO)
        text = act.read_text(encoding="utf-8")
        check_expression_shapes(text, str(rel), rep)
        try:
            doc = yaml.safe_load(text)
        except Exception as exc:
            rep.fail(f"YAML FAIL  {rel}: {exc}")
            continue
        print(f"YAML ok    {rel}")
        if not isinstance(doc, dict):
            continue
        if (doc.get("runs") or {}).get("using") != "composite":
            print(f"  SKIP     {rel}: not a composite action")
            continue

        check_action_contexts(text, str(rel), rep)

        for i, step in enumerate(doc["runs"].get("steps") or []):
            if isinstance(step, dict) and isinstance(step.get("run"), str):
                check_run(f"{rel}::{step.get('name', f'<step {i}>')}",
                          step["run"], rep)


def main():
    rep = Report()
    check_workflows(rep)
    check_actions(rep)
    print(f"\n{rep.scripts} shell block(s) checked with bash -n")
    return rep.rc


if __name__ == "__main__":
    sys.exit(main())