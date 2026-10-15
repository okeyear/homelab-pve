"""Generate the per-OS scripts the way a runner would, then bash -n them.

check_workflows.py only runs `bash -n` over each `run:` block. Everything a
step writes with `cat > foo.sh <<EOF` is a heredoc BODY, so bash parses it as
data, not code -- a syntax error in the generated script is invisible there and
only shows up as a red run on the PVE.

So instead of guessing what the runner expands, let bash do it: stub every
command the steps shell out to, execute each step with the workflow variables
filled in, and syntax-check whatever lands on disk.

The template workflows are now split three ways and share their bootstrap and
sealing steps with composite actions, so this also models the dispatch: it
evaluates each step's `if:` against the chosen OS and only runs what GitHub
would run. The guard steps for the not-yet-implemented distros are expected to
FAIL, and that is checked too -- "silently builds nothing" is the behaviour this
split exists to remove.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

import yaml

# Repo root: CI runs from a checkout, local runs from the absolute path below.
# REPO_ROOT wins when it is set.
REPO = os.environ.get("REPO_ROOT") or r"C:\Users\JackPeng\devops\github\homelab-pve"
WF_DIR = os.path.join(REPO, ".github", "workflows")

# git is not on PATH in this environment, and neither is its bash.
# BASH_ENV plus shell functions is what makes the stubs work (see make_prelude),
# and a step also runs real commands -- sed, cat, seq -- so bash has to be the
# LAUNCHER, not the raw MSYS2 shell. PortableGit's usr\bin\bash.exe starts with
# a PATH that has no /usr/bin in it, so every one of those commands dies with
# 127 and the case fails as "exit 127" with nothing on stdout to explain it.
# CI runs in a Debian slim image and finds a normal bash either way.
_WINDOWS_BASH = (
    r"C:\Program Files\Git\bin\bash.exe",
    r"D:\bin\PortableGit\bin\bash.exe",
)
BASH = (os.environ.get("BASH") or shutil.which("bash")
        or next((p for p in _WINDOWS_BASH if os.path.exists(p)),
                _WINDOWS_BASH[0]))

# commands the steps shell out to; all no-ops
STUBS = ["wget", "qemu-img", "qm", "ssh-keygen", "ssh", "rsync", "sudo",
         "tailscale", "apt-get", "pgrep"]

# (workflow file, OS input, extra env, expectation)
#   expectation "ok"    -> every run: step must succeed, scripts must parse
#   expectation "fails" -> the first run: step must fail with a "not
#                          implemented" style message, and no .sh may be left
CASES = [
    ("01a-setup-vm-os-template-deb.yml", "ubuntu24.04",
     {"VM_ID": "2404", "ubuntu_ver": "24.04"}, "ok"),
    ("01a-setup-vm-os-template-deb.yml", "ubuntu22.04",
     {"VM_ID": "2204", "ubuntu_ver": "22.04"}, "ok"),
    ("01a-setup-vm-os-template-deb.yml", "debian13",
     {"VM_ID": "2113", "DEBIAN_VERSION": "13", "DEBIAN_NAME": "trixie"}, "ok"),
    ("01a-setup-vm-os-template-deb.yml", "debian12",
     {"VM_ID": "2112", "DEBIAN_VERSION": "12", "DEBIAN_NAME": "bookworm"}, "ok"),
    ("01b-setup-vm-os-template-rhel.yml", "almalinux9",
     {"VM_ID": "2009", "almalinux_ver": "9"}, "ok"),
    ("01b-setup-vm-os-template-rhel.yml", "almalinux10",
     {"VM_ID": "20010", "almalinux_ver": "10"}, "ok"),
    ("01b-setup-vm-os-template-rhel.yml", "centos7",
     {"VM_ID": "2007", "CENTOS_VERSION": "7"}, "ok"),
    ("01b-setup-vm-os-template-rhel.yml", "centos9stream",
     {"VM_ID": "2109", "STREAM_VER": "9"}, "ok"),
    ("01b-setup-vm-os-template-rhel.yml", "centos10stream",
     {"VM_ID": "21010", "STREAM_VER": "10"}, "ok"),
    # the whole point of the split: these must NOT build anything quietly
    ("01c-setup-vm-os-template-other.yml", "openEuler2403",
     {"VM_ID": "2403", "OE_VERSION": "2403", "OE_RELEASE": "24.03-LTS"}, "ok"),
    ("01c-setup-vm-os-template-other.yml", "alinux3",
     {"VM_ID": "2003",
      "ALINUX3_IMAGE": "aliyun_3_x64_20G_nocloud_alibase_20260828.qcow2"}, "ok"),
    ("01-setup-vm-os-template.yml", "ubuntu24.04", {}, "fails"),
]

# An UNQUOTED heredoc body is expanded by the runner while it generates the
# script. A `${NAME}` in there that is not a runner-side variable therefore has
# to be written `\${NAME}`, or the runner splices an empty string in and the
# script ships with a silently blank value. This is the failure that cost the
# alinux3 template three runs: `- "${PUBKEY}"` went out as `- ""`, so the guest
# got an empty ssh_authorized_keys entry and no key at all.
HEREDOC_OPEN = re.compile(r"<<(-?)(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")

VALUES = {
    "github.event.inputs.OS": None,      # filled in per case
    "github.event.inputs.runner": "ubuntu-latest",
    "github.event.inputs.STORAGE": "local-zfs",
    "env.TAILSCALE_HOST": "pve",
    "env.TAILSCALE_NET": "taile80cb.ts.net",
}

EXPR = re.compile(r"\$\{\{\s*([^}]+?)\s*\}\}")
# each clause is `contains(github.event.inputs.OS, 'x')` or its negation, and a
# condition is clauses joined by && (the RHEL workflow guards centos7 and
# almalinux with a two-clause test)
CLAUSE = re.compile(r"^(!?)contains\(\s*github\.event\.inputs\.OS\s*,\s*'([^']+)'\s*\)$")

# `echo "FOO=$foo" >> "$GITHUB_ENV"` -- the names a step publishes to later steps
GITHUB_ENV_WRITE = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)=.*>>\s*"?\$GITHUB_ENV')

# a `${NAME}` reference left standing in a generated script
VAR_REF = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def subst(text, os_input):
    def repl(m):
        key = m.group(1)
        if key == "github.event.inputs.OS":
            return os_input
        if key not in VALUES:
            raise SystemExit(f"unmapped workflow expression: {key}")
        return VALUES[key]
    return EXPR.sub(repl, text)


def wants(step, os_input):
    """Evaluate the `if:` GitHub would apply. Only the forms we actually use."""
    cond = step.get("if")
    if not isinstance(cond, str):
        return True
    cond = cond.strip()
    if cond.startswith("${{") and cond.endswith("}}"):
        cond = cond[3:-2].strip()
    result = True
    for clause in cond.split("&&"):
        m = CLAUSE.match(clause.strip())
        if not m:
            raise SystemExit(f"gencheck does not know how to evaluate if: {cond!r}")
        # group 1 is the "!" or empty -- compare as a bool, not with `is not ""`,
        # which is always True and silently turns every contains() into a no-op
        neg = bool(m.group(1))
        result = result and ((m.group(2) in os_input) != neg)
    return result


def make_prelude(d):
    """Shadow every external command the steps shell out to.

    PATH prepending does NOT work here: Git bash puts its own /usr/bin and
    /ucrt64/bin in front, so a stub directory loses to /usr/bin/ssh and the
    step really opens a connection to the PVE host. BASH_ENV is sourced for
    non-interactive shells before -c runs, and shell functions take precedence
    over PATH lookup, so define them instead.
    """
    prelude = os.path.join(d, "prelude.sh")
    with open(prelude, "w", newline="\n") as fh:
        for name in STUBS:
            fh.write(f"{name}() {{ :; }}\n")
        fh.write("readonly -f " + " ".join(STUBS) + "\n")
    return prelude


def unescaped_in_unquoted_heredoc(run_text, runner_only):
    r"""${NAME} in an unquoted heredoc that the runner cannot possibly fill.

    Everything the runner knows is `runner_only`. A name outside it is either
    a PVE-side variable -- which must keep its backslash so it survives to the
    host -- or a typo. Either way an unescaped ${NAME} here ships out blank.

    A QUOTED heredoc's body is literal data, so it is consumed and skipped
    whole. That matters because the guest scripts are `cat > setup_x.sh <<'EOF'`
    and the repo file inside them is a nested `<<REPO`: the runner never sees
    either one, and treating the nested opener as real gives dozens of false
    positives on ${MIRROR}, ${RELEASE} and ${GPGKEY}.
    """
    bad = []
    lines = run_text.split("\n")
    i = 0
    while i < len(lines):
        m = HEREDOC_OPEN.search(lines[i])
        if not m:
            i += 1
            continue
        delim = m.group(3)
        quoted = bool(m.group(2))
        i += 1
        while i < len(lines) and lines[i].strip() != delim:
            if not quoted:
                seen = set()
                for hit in VAR_REF.finditer(lines[i]):
                    # an escaped one is deliberate: the target shell expands it
                    if hit.start() > 0 and lines[i][hit.start() - 1] == "\\":
                        continue
                    name = hit.group(1)
                    if name in runner_only or name in seen:
                        continue
                    seen.add(name)
                    bad.append(
                        f"line {i + 1}: ${{{name}}} in an unquoted "
                        f"heredoc but is not a runner variable -- write it as "
                        f"\\${{{name}}}, or the runner ships it blank"
                    )
            i += 1
        i += 1
    return bad


def leaked_runner_vars(fn, content, runner_only):
    r"""Runner-side variables that survived into a PVE-side template script.

    `bash -n` cannot see this: `${ALINUX3_IMAGE}` is valid bash whether or not
    anything ever assigns it. In a `*_tpl.sh` the only variables in scope are the
    ones the script assigns itself, so a leftover reference to a runner variable
    is always empty at runtime. That is how alinux3 spent a run doing
    `wget https://alinux3.oss-cn-hangzhou.aliyuncs.com/` -- the bare bucket root,
    403 -- because the heredoc had `\${ALINUX3_IMAGE}` and so expanded nothing.
    """
    if not runner_only:
        return []
    assigned = set(re.findall(r"^\s*([A-Za-z_][A-Za-z0-9_]*)=", content, re.M))
    assigned |= set(re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)=(?![=>])", content))
    bad = []
    for name in sorted(set(VAR_REF.findall(content)) & runner_only - assigned):
        if name in ("PATH", "HOME"):
            continue
        bad.append(
            f"{fn}: ${{{name}}} is a runner-side variable that was not expanded, "
            f"so it is empty when the script runs on the PVE host -- "
            f"drop the backslash in the workflow so the runner bakes in the value"
        )
    return bad


def run_case(wf_name, os_input, extra_env, expectation):
    with open(os.path.join(WF_DIR, wf_name), encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)

    jobs = doc.get("jobs") or {}
    job = next(iter(jobs.values()))
    steps = job.get("steps") or []

    label = f"{wf_name} / {os_input}"
    problems = []
    made = []

    d = tempfile.mkdtemp(prefix="gencheck-")
    try:
        env = dict(os.environ)
        env["BASH_ENV"] = make_prelude(d)
        env["GITHUB_ENV"] = os.path.join(d, "github_env")
        env["STORAGE"] = "local-zfs"
        env["CIDR"] = "10.10.10"
        env["DNS"] = "223.5.5.5"
        env.update(extra_env)

        guard_ran = False
        executed = []
        # Names that only exist on the runner. A `*_tpl.sh` is generated here and
        # then executed on the PVE host, so a reference to one of these that
        # survived generation (i.e. the workflow escaped it) is undefined at
        # runtime -- syntactically fine, silently empty.
        runner_only = set(extra_env) | set(doc.get("env") or {})
        for step in steps:
            if not isinstance(step, dict) or not isinstance(step.get("run"), str):
                continue  # `uses:` composite action, nothing to execute here
            name = step.get("name", "<unnamed>")
            if not wants(step, os_input):
                continue
            guard_ran = True
            runner_only |= set(GITHUB_ENV_WRITE.findall(step["run"]))
            executed.append((name, step["run"]))
            r = subprocess.run([BASH, "-c", subst(step["run"], os_input)],
                               cwd=d, env=env, capture_output=True, text=True,
                               encoding="utf-8", errors="replace")
            if r.returncode != 0:
                if expectation == "fails":
                    if "not implemented" not in r.stdout:
                        problems.append(
                            f"{name}: expected a 'not implemented' message, got:\n{r.stdout[:400]}")
                    return label, made, problems, True
                problems.append(f"{name}: exit {r.returncode}\n{r.stdout[-800:]}")
                return label, made, problems, False
            if expectation == "fails":
                problems.append(f"{name}: was expected to fail but exited 0")
                return label, made, problems, False

        if expectation == "fails":
            if not guard_ran:
                problems.append("no step matched the OS, so nothing failed")
            return label, made, problems, False

        # checked last: the runner-side variable set is only complete once every
        # step has been walked and all $GITHUB_ENV writes have been seen
        for name, text in executed:
            for msg in unescaped_in_unquoted_heredoc(text, runner_only):
                problems.append(f"{name}: {msg}")

        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".sh") or fn == "prelude.sh":
                continue
            path = os.path.join(d, fn)
            with open(path, encoding="utf-8", errors="replace") as fh:
                content = fh.read()
            # a heredoc that never terminated shows up as a stray EOF marker
            if re.search(r"^EOF$", content, re.M):
                problems.append(f"{fn}: heredoc terminator leaked into output")
            if fn.endswith("_tpl.sh"):
                problems.extend(leaked_runner_vars(fn, content, runner_only))
            c = subprocess.run([BASH, "-n", path], capture_output=True, text=True,
                               encoding="utf-8", errors="replace")
            if c.returncode != 0:
                problems.append(f"{fn}: bash -n failed\n{c.stderr.strip()}")
            else:
                made.append((fn, len(content.splitlines())))
        if not made:
            problems.append("no scripts were generated -- the dispatch did nothing")
        # NOTE: this used to `return ..., True` unconditionally, which silently
        # dropped every problem collected while scanning the generated scripts --
        # a `bash -n` failure showed up as a script simply missing from the
        # summary, and the case still printed "ok". That is the exact
        # "silently builds nothing" failure this harness exists to catch.
        return label, made, problems, not problems
    finally:
        shutil.rmtree(d, ignore_errors=True)


def main():
    failed = 0
    total = 0
    for wf_name, os_input, extra, expectation in CASES:
        label, made, problems, ok = run_case(wf_name, os_input, extra, expectation)
        total += 1
        if not ok:
            failed += 1
            print(f"  FAIL {label}")
            for p in problems:
                print(f"       {p}")
        elif expectation == "fails":
            print(f"  ok   {label}  -> refused as expected")
        else:
            names = ", ".join(f"{n} ({v} lines)" for n, v in made)
            print(f"  ok   {label}  -> {names}")
    print(f"\n{total - failed}/{total} dispatch case(s) passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())