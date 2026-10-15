"""Dump what gencheck actually generates for the archlinux case.

gencheck passes on syntax, which is not the same as correct. Three things can
be syntactically fine and still wrong at runtime, and all three are invisible
to bash -n:

  - `${STORAGE}` left escaped arrives on the PVE empty
  - pacman's own `$repo` / `$arch` eaten by the runner's shell instead of
    arriving literal for pacman to substitute
  - `ssh_authorized_keys: [""]` because PUBKEY expanded one level too early
"""
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gencheck  # noqa: E402

WANT = "setup_archlinux.sh" if len(sys.argv) < 2 or sys.argv[1] != "tpl" else "setup_archlinux_tpl.sh"

d = Path(tempfile.mkdtemp(prefix="archdump-"))
# reuse gencheck's own machinery, but keep the directory it works in
orig_mkdtemp = gencheck.tempfile.mkdtemp
orig_rmtree = gencheck.shutil.rmtree
gencheck.tempfile.mkdtemp = lambda **kw: str(d)
gencheck.shutil.rmtree = lambda *a, **kw: None

label, made, problems, ok = gencheck.run_case(
    "01c-setup-vm-os-template-other.yml", "archlinux", {"VM_ID": "20000"}, "ok")
gencheck.tempfile.mkdtemp = orig_mkdtemp
gencheck.shutil.rmtree = orig_rmtree

print(f"case={label}  ok={ok}  problems={problems}")
print(f"generated: {made}")
print()

path = d / WANT
text = path.read_text(encoding="utf-8")
print(f"===== {WANT} ({len(text.splitlines())} lines) =====")
print(text)

if WANT == "setup_archlinux.sh":
    print("===== assertions =====")
    # pacman's $repo/$arch must still be literal in the guest script
    assert "Server = https://mirrors.cernet.edu.cn/archlinux/$repo/os/$arch" in text, \
        "pacman $repo/$arch was expanded away"
    print("ok  pacman $repo/$arch survived into the guest script")
    assert "pacman -Syu --noconfirm" in text
    assert "pacman -Sy " not in text, "a bare -Sy would be a partial upgrade"
    print("ok  full -Syu, no partial -Sy")
else:
    print("===== assertions =====")
    # runner-side variables must be baked in, not escaped
    assert "${STORAGE}" not in text, "${STORAGE} survived generation -> empty on the PVE"
    assert "local-zfs" in text, "STORAGE was not expanded to the real storage name"
    print("ok  ${STORAGE} expanded to local-zfs")
    assert "Arch-Linux-x86_64-cloudimg.qcow2" in text
    print("ok  image name is the current one, not archlinux.qcow2")
    assert "- \"${PUBKEY}\"" in text, "PUBKEY lost its backslash -> snippet ships [\"\"]"
    print('ok  snippet keeps ssh_authorized_keys: ["${PUBKEY}"] for the PVE to expand')
    assert "${ARCH_IMAGE}" in text, "ARCH_IMAGE reference did not survive generation"
    assert "qm importdisk 20000 ${ARCH_IMAGE}" in text, \
        "ARCH_IMAGE is assigned on the PVE side and must be expanded there, not by the runner"
    print("ok  ARCH_IMAGE is assigned and expanded on the PVE side")
    assert "--cpu cputype=host" not in text, \
        "cputype=host would make the template un-clonable onto an older CPU"
    print("ok  no cputype=host")
print("\nALL OK")
