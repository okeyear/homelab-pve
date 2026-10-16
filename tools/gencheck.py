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

# commands the steps shell out to that have no state worth modelling; all no-ops
# sha256sum is here because setup_archlinux_tpl.sh verifies the qcow2 against the
# mirror's .SHA256. Left unstubbed it would really run, read whatever the stubbed
# wget left on stdin (nothing), and fail every case with a checksum error that
# has nothing to do with the script.
# sleep is here because 02 polls its guest-ssh probe for up to 60 rounds 5s
# apart. Left real, the "guests never answer" case would spend five minutes
# proving what a no-op sleep proves instantly -- and a test nobody waits for
# is a test that gets skipped.
# qm / pct / ssh / sshpass are NOT here -- see FAKE_PVE below.
STUBS = ["wget", "qemu-img", "ssh-keygen", "rsync", "sudo",
         "tailscale", "apt-get", "pgrep", "sha256sum", "sleep"]


# `qm` used to be `qm() { :; }`. That was fine while the generated scripts only
# ever wrote values and then went quiet, but 02-create-vms.yml now reads its own
# writes back out of `qm config` and asserts on them -- and a stub that answers
# with nothing reports every one of those assertions as a failure. So `qm` keeps
# a little state here: one file per VM under $FAKE_PVE, written by
# clone/set/start/disk-resize and read back by config/status.
#
# It is still a stub -- it boots nothing. But it is a stub that can be WRONG,
# which is what makes the negative cases worth running: seed a template without
# `template: 1` and the script must refuse, seed a `ssh-down` marker and the
# guest probe must fail. Neither of those can be shown with a no-op stub.
FAKE_PVE = r'''
FAKE_CFG() { printf '%s/cfg-%s' "$FAKE_PVE" "$1"; }

FAKE_UPSERT() {   # FAKE_UPSERT <vmid> <key> <value>
  local f tmp
  f=$(FAKE_CFG "$1"); tmp="$f.tmp"
  : > "$tmp"
  grep -v "^$2:" "$f" > "$tmp" 2>/dev/null || true
  printf '%s: %s\n' "$2" "$3" >> "$tmp"
  sort "$tmp" > "$f" 2>/dev/null || cp "$tmp" "$f"
  rm -f "$tmp"
  return 0
}

FAKE_DROP() {     # FAKE_DROP <vmid> <key>
  local f tmp
  f=$(FAKE_CFG "$1"); tmp="$f.tmp"
  grep -v "^$2:" "$f" > "$tmp" 2>/dev/null || true
  cp "$tmp" "$f" 2>/dev/null || true
  rm -f "$tmp"
  return 0
}

qm() {
  local sub id src dst key val out disk size f
  sub="$1"; shift || true
  case "$sub" in
    config)
      id="$1"
      if [ -f "$(FAKE_CFG "$id")" ]; then cat "$(FAKE_CFG "$id")"; return 0; fi
      echo "Configuration file 'nodes/qemu-server/$id.conf' does not exist" >&2
      return 2 ;;
    status)
      id="$1"
      if [ -f "$(FAKE_CFG "$id")" ]; then
        grep -m1 -E '^(status|template):' "$(FAKE_CFG "$id")" 2>/dev/null || echo "status: unknown"
        return 0
      fi
      echo "Configuration file 'nodes/qemu-server/$id.conf' does not exist" >&2
      return 2 ;;
    clone)
      src="$1"; dst="$2"
      if [ ! -f "$(FAKE_CFG "$src")" ]; then
        echo "clone failed: VM $src does not exist" >&2; return 1
      fi
      cp "$(FAKE_CFG "$src")" "$(FAKE_CFG "$dst")"
      # a clone of a template is not itself a template
      FAKE_DROP "$dst" template
      echo "creating a clone of VM $src with ID $dst" ;;
    set)
      id="$1"; shift
      out="update VM $id:"
      while [ $# -ge 1 ]; do
        key="${1#--}"; val="${2-}"
        if [ "$key" = "$1" ]; then shift; continue; fi
        shift 2 || shift $#
        # PVE normalises the option name to the config property name: run #9
        # logged `update VM 1011: -cores 2` for `qm set --core 2`. Without
        # this the fake would keep a stray `core:` key AND leave the real
        # `cores:` untouched, and the script's `^cores:` assertion would then
        # fail for a reason that exists only in the stub.
        [ "$key" = "core" ] && key="cores"
        out="$out -$key $val"
        if [ "$key" = "cipassword" ]; then
          out="$out <hidden>"     # PVE hides it and keeps it out of the config
        else
          FAKE_UPSERT "$id" "$key" "$val"
        fi
      done
      echo "$out" ;;
    start)
      id="$1"
      FAKE_UPSERT "$id" status "running"
      FAKE_DROP "$id" template
      echo "generating cloud-init ISO" ;;
    shutdown)
      id="$1"
      if [ -f "$(FAKE_CFG "$id")" ]; then FAKE_UPSERT "$id" status "stopped"; fi ;;
    destroy)
      rm -f "$(FAKE_CFG "$1")" ;;
    disk)           # qm disk resize <id> <disk> <size>
      shift
      id="$1"; disk="$2"; size="$3"
      f=$(FAKE_CFG "$id")
      if [ -f "$f" ]; then
        sed -i "s|^\(${disk}: .*\),size=[^ ,]*|\1,size=${size}|" "$f" 2>/dev/null || true
      else
        printf '%s: local-zfs:vm-%s-disk-0,size=%s\n' "$disk" "$id" "$size" > "$f"
      fi ;;
    list)
      printf '%-8s %-22s %-10s %s\n' VMID NAME STATUS MEM
      for f in "$FAKE_PVE"/cfg-*; do
        [ -f "$f" ] || continue
        id=$(basename "$f"); id="${id#cfg-}"
        printf '%-8s %-22s %-10s %s\n' "$id" \
          "$(grep -m1 '^name:' "$f" | cut -d' ' -f2-)" \
          "$(grep -m1 '^status:' "$f" | cut -d' ' -f2-)" \
          "$(grep -m1 '^memory:' "$f" | cut -d' ' -f2-)"
      done ;;
    *) : ;;
  esac
  return 0
}

# no LXC container ever shares a number with these VMs
pct() { if [ "$1" = "status" ]; then return 1; fi; return 0; }

# `ssh-down` must only knock out the GUEST probe. The step that generates and
# ships setup_vms.sh reaches PVE as root@<tailscale host>, and letting the
# marker take that one down too would make the case "pass" for the wrong
# reason -- the step failing, not the guest check inside the script.
ssh() {
  local a
  for a in "$@"; do
    case "$a" in
      vagrant@10.*)
        if [ -f "$FAKE_PVE/ssh-down" ]; then return 1; fi ;;
    esac
  done
  return 0
}

# sshpass -p <pw> ssh ... : drop the password pair and delegate, so the password
# fallback is judged by the same fake ssh as the key path
sshpass() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -p) shift 2 ;;
      *)  break ;;
    esac
  done
  ssh "$@"
}
'''

# The template 01a's ubuntu26.04 run leaves on PVE, reduced to the keys 02 reads
# back. `status: stopped` and `template: 1` are the two the guards turn on.
TPL_2604 = """\
cores: 2
ide2: local-zfs:vm-2604-cloudinit,media=cdrom
memory: 4096
name: ubuntu26.04Tpl
net0: virtio=BC:24:11:31:ED:B9,bridge=vmbr1
scsi0: local-zfs:base-2604-disk-0,size=20G
scsihw: virtio-scsi-pci
status: stopped
tags: template;ubuntu26.04
template: 1
"""


# (workflow file, OS input, extra env, expectation, [options])
#   expectation "ok"    -> every run: step must succeed, scripts must parse
#   expectation "fails" -> the first run: step must fail with a "not
#                          implemented" style message, and no .sh may be left
#   options is an optional dict:
#     "seed"    {filename: content} written into the case dir before the step
#                runs -- this is where the fake PVE's template lands
#     "execute" [script, ...] run each generated script with bash INSTEAD of
#                only `bash -n`-ing it. 02's step ships setup_vms.sh to PVE
#                and runs it there, and without this the script is never
#                executed and its ~40 lines of assertions are never run.
#     "forbid"  [(regex, why)] patterns that must not appear in any run: block
#                the case executes.
CASES = [
    ("01a-setup-vm-os-template-deb.yml", "ubuntu24.04",
     {"VM_ID": "2404", "ubuntu_ver": "24.04"}, "ok"),
    ("01a-setup-vm-os-template-deb.yml", "ubuntu22.04",
     {"VM_ID": "2204", "ubuntu_ver": "22.04"}, "ok"),
    # 2604 is the template 02 clones from, and it was the one release 01a
    # offered but gencheck never exercised
    ("01a-setup-vm-os-template-deb.yml", "ubuntu26.04",
     {"VM_ID": "2604", "ubuntu_ver": "26.04"}, "ok"),
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
    ("01c-setup-vm-os-template-other.yml", "archlinux",
     {"VM_ID": "20000"}, "ok"),
    # the guard has to keep refusing things it has never heard of
    ("01c-setup-vm-os-template-other.yml", "gentoo",
     {"VM_ID": "2999"}, "fails"),
    ("01-setup-vm-os-template.yml", "ubuntu24.04", {}, "fails"),

    # 02 used to have no coverage at all, and it is the one workflow whose
    # whole job is to assert on what it just did to PVE.
    ("02-create-vms.yml", "ubuntu26.04",
     {"vm_prefix": "k8s-", "ip_list": "11,101,102", "vm_user": "vagrant"},
     "ok", {"seed": {"cfg-2604": TPL_2604}, "execute": ["setup_vms.sh"],
            "forbid": [(r"['\"]\s*bash -s\s*['\"]",
                        "a remote command of `bash -s`. bash reads a `-s` program "
                        "from stdin lazily and every command the script runs "
                        "inherits that stdin, so the first ssh in the guest probe "
                        "eats the rest of the script: bash hits EOF, finishes "
                        "early, and exits with the status of the last echo -- 0. "
                        "Run #11 lost its whole failure block that way and the "
                        "step came back green. Ship the script to a file and run "
                        "that. (The pattern matches the quoted remote command, not "
                        "the prose that explains why not to.)")]}),
    # not a template -> refuse to clone a live VM
    ("02-create-vms.yml", "ubuntu26.04",
     {"vm_prefix": "k8s-", "ip_list": "11,101,102", "vm_user": "vagrant"},
     "fails", {"seed": {"cfg-2604": TPL_2604.replace("template: 1\n", "")},
               "execute": ["setup_vms.sh"]}),
    # no tags -> refuse rather than clone into an empty --tags
    ("02-create-vms.yml", "ubuntu26.04",
     {"vm_prefix": "k8s-", "ip_list": "11,101,102", "vm_user": "vagrant"},
     "fails", {"seed": {"cfg-2604": TPL_2604.replace("tags: template;ubuntu26.04\n", "")},
               "execute": ["setup_vms.sh"]}),
    # the VMs come up but the guests never answer ssh -> that is a failure,
    # not a pass. This is the check run #9 did not have.
    ("02-create-vms.yml", "ubuntu26.04",
     {"vm_prefix": "k8s-", "ip_list": "11,101,102", "vm_user": "vagrant"},
     "fails", {"seed": {"cfg-2604": TPL_2604, "ssh-down": ""},
               "execute": ["setup_vms.sh"]}),
    # an unknown template name must not reach `qm clone` as an empty id
    ("02-create-vms.yml", "ubuntu99.04",
     {"vm_prefix": "k8s-", "ip_list": "11,101,102", "vm_user": "vagrant"},
     "fails", {"seed": {"cfg-2604": TPL_2604}}),
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
    "github.event.inputs.vm_template": None,  # 02 spells the same choice differently
    "github.event.inputs.runner": "ubuntu-latest",
    "github.event.inputs.STORAGE": "local-zfs",
    "github.event.inputs.vm_prefix": "k8s-",
    "github.event.inputs.ip_list": "11,101,102",
    "github.event.inputs.vm_user": "vagrant",
    "env.TAILSCALE_HOST": "pve",
    "env.TAILSCALE_NET": "taile80cb.ts.net",
    # 02 reads these back out of $GITHUB_ENV, so the runner has to bake the
    # literals in. VM_TEMPLATE_ID is what "Get VM Template ID" resolves
    # ubuntu26.04 to; the other three are copied from the dispatch inputs.
    "env.VM_TEMPLATE_ID": "2604",
    "env.VM_PREFIX": "k8s-",
    "env.VM_USER": "vagrant",
    "env.CIDR": "10.10.10",
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
        if key in ("github.event.inputs.OS", "github.event.inputs.vm_template"):
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
        fh.write(FAKE_PVE)
        fh.write("\nreadonly -f " + " ".join(STUBS) + "\n")
        for name in ("qm", "pct", "ssh", "sshpass",
                     "FAKE_CFG", "FAKE_UPSERT", "FAKE_DROP"):
            fh.write(f"readonly -f {name}\n")
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


def run_case(wf_name, os_input, extra_env, expectation, opts=None):
    opts = opts or {}
    seed = opts.get("seed") or {}
    execute = opts.get("execute") or []
    # [(regex, why)] patterns that must not appear in any run: block this case
    # executes. For structural mistakes that no amount of executing the
    # generated script can catch.
    forbid = opts.get("forbid") or []

    with open(os.path.join(WF_DIR, wf_name), encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)

    jobs = doc.get("jobs") or {}
    job = next(iter(jobs.values()))
    steps = job.get("steps") or []

    label = f"{wf_name} / {os_input}" + (f" [{opts['why']}]" if opts.get("why") else "")
    problems = []
    made = []

    d = tempfile.mkdtemp(prefix="gencheck-")
    try:
        # the fake PVE keeps its per-VM state as cfg-<vmid> files in here
        for fn, content in seed.items():
            with open(os.path.join(d, fn), "w", newline="\n") as fh:
                fh.write(content)

        env = dict(os.environ)
        env["BASH_ENV"] = make_prelude(d)
        env["GITHUB_ENV"] = os.path.join(d, "github_env")
        # 02's "Check if already ssh key-based" writes to $GITHUB_OUTPUT. Left
        # unset, `>> $GITHUB_OUTPUT` is an ambiguous redirect and the step exits
        # 1 -- which reads as "the ssh probe failed" rather than "the harness
        # forgot a file".
        env["GITHUB_OUTPUT"] = os.path.join(d, "github_output")
        env["STORAGE"] = "local-zfs"
        env["CIDR"] = "10.10.10"
        env["DNS"] = "223.5.5.5"
        env["FAKE_PVE"] = d
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
            # Run the step from a FILE, never as `bash -c <string>`.
            # MSYS2 silently truncates a long -c argument on Windows: the
            # 02 step's body is ~9.7 KB and came out cut at 8187 characters,
            # mid-line, inside a heredoc. Nothing errored -- the heredoc just
            # ended early and the generated setup_vms.sh was 12 lines short
            # with an unterminated echo, which is what `bash -n` caught. A
            # harness that truncates the very text it is checking is worse
            # than no harness, because the truncation reads as a finding
            # about the workflow.
            step_path = os.path.join(d, f"_step{len(executed)}.sh")
            with open(step_path, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(subst(step["run"], os_input))
            r = subprocess.run([BASH, step_path],
                               cwd=d, env=env, capture_output=True, text=True,
                               encoding="utf-8", errors="replace")
            if r.returncode != 0:
                if expectation == "fails" and not execute:
                    if "not implemented" not in r.stdout:
                        problems.append(
                            f"{name}: expected a 'not implemented' message, got:\n{r.stdout[:400]}")
                    return label, made, problems, True
                problems.append(f"{name}: exit {r.returncode}\n{r.stdout[-800:]}")
                return label, made, problems, False
            # A case that declares `execute` is expecting the failure to come
            # out of the generated script, not out of the step that writes it:
            # 02's step is `cat setup_vms.sh | ssh ... 'bash -s'`, so it
            # succeeds at generating the script and the refusal happens later.
            if expectation == "fails" and not execute:
                problems.append(f"{name}: was expected to fail but exited 0")
                return label, made, problems, False

        if expectation == "fails" and not execute:
            if not guard_ran:
                problems.append("no step matched the OS, so nothing failed")
            return label, made, problems, False

        # checked last: the runner-side variable set is only complete once every
        # step has been walked and all $GITHUB_ENV writes have been seen
        for name, text in executed:
            for msg in unescaped_in_unquoted_heredoc(text, runner_only):
                problems.append(f"{name}: {msg}")
            for pattern, why in forbid:
                if re.search(pattern, text):
                    problems.append(f"{name}: {why}")

        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".sh"):
                continue
            # prelude.sh is the stub library, _stepN.sh is the step's own text
            # that we just executed. Neither is a script the workflow generates.
            if fn == "prelude.sh" or fn.startswith("_step"):
                continue
            path = os.path.join(d, fn)
            with open(path, encoding="utf-8", errors="replace") as fh:
                content = fh.read()
            # a heredoc that never terminated shows up as a stray EOF marker
            if re.search(r"^EOF$", content, re.M):
                problems.append(f"{fn}: heredoc terminator leaked into output")
            # A script this case actually runs on the PVE host is held to the
            # same "no unexpanded runner variables" rule as a *_tpl.sh, for
            # the same reason: `${ALINUX3_IMAGE}` is valid bash whether or
            # not anything assigns it, and setup_vms.sh does run over there.
            if fn.endswith("_tpl.sh") or fn in execute:
                problems.extend(leaked_runner_vars(fn, content, runner_only))
            c = subprocess.run([BASH, "-n", path], capture_output=True, text=True,
                               encoding="utf-8", errors="replace")
            if c.returncode != 0:
                problems.append(f"{fn}: bash -n failed\n{c.stderr.strip()}")
                continue

            if fn in execute:
                e = subprocess.run([BASH, path], cwd=d, env=env,
                                   capture_output=True, text=True,
                                   encoding="utf-8", errors="replace")
                if expectation == "fails":
                    if e.returncode == 0:
                        problems.append(
                            f"{fn}: was expected to refuse, but it ran to "
                            f"completion -- the guard it is supposed to make is "
                            f"not firing"
                        )
                elif e.returncode != 0:
                    problems.append(
                        f"{fn}: exit {e.returncode} against the fake PVE\n"
                        f"--- stdout tail ---\n{e.stdout[-2500:]}\n"
                        f"--- stderr tail ---\n{e.stderr[-1500:]}")
                made.append((fn, len(content.splitlines()), e.returncode))
            else:
                made.append((fn, len(content.splitlines())))

        for fn in execute:
            if not os.path.exists(os.path.join(d, fn)):
                problems.append(
                    f"{fn}: the case says to run it, but the step never "
                    f"generated it")
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
    for case in CASES:
        wf_name, os_input, extra, expectation = case[:4]
        opts = case[4] if len(case) > 4 else None
        label, made, problems, ok = run_case(wf_name, os_input, extra, expectation, opts)
        total += 1
        if not ok:
            failed += 1
            print(f"  FAIL {label}")
            for p in problems:
                print(f"       {p}")
        elif expectation == "fails":
            ran = ", ".join(n for n, *_ in made) or "nothing"
            print(f"  ok   {label}  -> refused as expected ({ran})")
        else:
            def describe(m):
                if len(m) > 2:
                    return f"{m[0]} ({m[1]} lines, exit {m[2]})"
                return f"{m[0]} ({m[1]} lines)"
            print(f"  ok   {label}  -> {', '.join(describe(m) for m in made)}")
    print(f"\n{total - failed}/{total} dispatch case(s) passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())