"""NUL-safe WSL boot-context capture for the bench run log.

bench.bat used to append the boot context (container + shape knobs +
card state) straight from a `wsl -d <distro>` call. When the WSL
service cannot see the named distro (a mid-restart window; the VM and
everything serving out of it can keep running the whole time), the
wsl.exe launcher pads its stdout pipe with NUL bytes before writing
the error text, and the raw blob lands in run.log - where it then
reads as binary in any editor.

This script runs the same probe, strips the padding, and appends
either the clean context or a one-line failure note. The bench
continues either way: the probes are the data, the context is the
bonus. If the note lands, the context can be re-captured by re-running
bench.bat once the distro answers again.
"""

import argparse
import re
import subprocess
import sys


def clean(raw: bytes) -> str:
    """Drop NUL/control padding; keep the printable residue."""
    stripped = re.sub(rb"[\x00-\x08\x0b-\x1f]", b"", raw)
    text = stripped.decode("utf-8", "replace")
    return "\n".join(line.rstrip() for line in text.splitlines() if line.strip())


def first_error_line(text: str) -> str:
    for line in text.splitlines():
        if "Error" in line or "distribution" in line.lower():
            return line.strip()
    return ""


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--distro", default="Ubuntu")
    ap.add_argument("--repo-wsl", required=True,
                    help="the repo's WSL-side root (reporoot.ps1's REPO_WSL)")
    ap.add_argument("--model", required=True)
    ap.add_argument("--append", required=True, help="the run log to append to")
    a = ap.parse_args()

    ctx_script = "{}/{}/vllm/scripts/bench-context.sh".format(a.repo_wsl, a.model)
    returncode = 0
    try:
        p = subprocess.run(
            ["wsl", "-d", a.distro, "--", "bash", ctx_script],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, timeout=300)
        raw = p.stdout
        returncode = p.returncode
    except Exception as e:  # the wsl exe itself refusing to launch
        raw = str(e).encode()
        returncode = -1

    had_nuls = b"\x00" in raw
    text = clean(raw)
    # The distro-error shape: the launcher's message survives the NUL
    # stripping but says nothing about the boot. Anything else that
    # printed (including the script's own "container: ABSENT" line,
    # which exits 2 by design) is the context itself.
    distro_err = "no distribution" in text.lower() or "wsl_e_" in text.lower()
    with open(a.append, "a", encoding="utf-8") as f:
        if had_nuls or distro_err or not text:
            err = first_error_line(text) or "no usable output " \
                "(wsl exit {!r}, {} padding byte(s))".format(
                    returncode, len(re.findall(rb"[\x00-\x08\x0b-\x1f]", raw)))
            f.write("[bench] boot-context: the WSL probe failed this run - "
                    "{}\n".format(err))
            f.write("         the tier itself is up (the route check passed);\n"
                    "         the shape knobs for this boot are in its boot-window\n"
                    "         log. If the distro answers again, a re-run of this\n"
                    "         bat re-captures the context in a fresh run folder.\n")
        else:
            f.write(text + "\n")


if __name__ == "__main__":
    main()
