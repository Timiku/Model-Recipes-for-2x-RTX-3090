#!/usr/bin/env python3
"""yml-provenance — the provenance guard for authored vLLM compose files.

An authored model-recipes vLLM yml (e.g. qwen3.8-27b/vllm/package/mtp.yml)
is two things:

  1. a provenance header (this repo's text) ending in a sentinel line,
  2. a body: the in-place source file verbatim, with ONLY the deltas
     documented in the header applied.

The guard enforces that nothing else ever drifts:

  build   --source SRC --out OUT --header HDR --subst TABLE
          Apply the substitution table to SRC, write HDR + sentinel + body
          to OUT. Table ops:
              REPLACE
              <old line>
              <new line>            (1..n lines)
              ---
              INSERT_AFTER
              <anchor line>
              <inserted line>       (1..n lines)
              ---
          Every <old line> / <anchor line> must occur EXACTLY ONCE in the
          (evolving) body; otherwise the build fails.

  check   --yml YML --source SRC --manifest MANIFEST
          Diff the body against SRC. Every changed line must match a manifest
          pattern (DEL = line removed from the source, ADD = line added to
          the body); every manifest pattern must match at least one line.
          Both directions fail loudly — an undocumented change or a stale
          pattern is a gate failure.

  lint    --yml YML
          Static guard that stays meaningful forever (even after the
          in-place source retires at cutover): sentinel present; no
          in-place residue (cross-model mounts, models-cache, stock-shape
          knobs, relative host mounts); required knobs present.

Exit codes: 0 pass, 1 gate failure, 2 usage error.
Runs anywhere with CPython (the WSL Ubuntu distro and Windows both qualify).
"""
import argparse
import difflib
import re
import sys

SENTINEL = "# ===[model-recipes:provenance:end]==="

# In-place residue: any of these in a body means the file still points at
# the pre-09-08 layout (the one config.env, the ${HOME} mirror's vllm
# sub-tree, the 3.6-era patch dirs). The relative tree mount is the 09-08
# house form (the yml's own directory) and is not forbidden.
FORBIDDEN = [
    (r"qwen3\.6-27b/", "cross-model (3.6) patch mount"),
    (r"models-cache", "in-place MODEL_DIR default (models-cache)"),
    (r"ESTATE_CONTAINER", "stock-shape container_name knob"),
    (r"CLUB3090_RESTART", "stock-shape restart knob"),
    (r"\.bak-", "a .bak reference"),
    (r"\$\{HOME\}/model-recipes-rt/[^/\n]*/vllm/", "the old WSL-mirror mount form"),
]
# Every authored tier must carry these (the vLLM boot invariants, AGENTS.md):
# the 0.29.0 two-tier form pins the image as a literal and carries the device
# pin as a map key, so the patterns are the map/stock forms, not the old
# env-list `=` forms (the 0.28.0 gate checked `VLLM_IMAGE`/`=0,2`).
REQUIRED = [
    (r"image: vllm/vllm-openai:", "the image pin (literal, the 0.29.0 anchor)"),
    (r"WEIGHTS_DIR", "weights dir knob"),
    (r"TARGET_MODEL", "checkpoint selection knob"),
    (r"CHAT_TEMPLATE", "chat template knob"),
    (r"--chat-template", "chat template flag"),
    (r"/templates/", "templates mount"),
    (r"CUDA_VISIBLE_DEVICES", "the device pin"),
    (r"PCI_BUS_ID", "the PCI_BUS_ID order"),
    (r"expandable_segments:False", "the alloc-conf invariant"),
    (r"VLLM_WSL2_ENABLE_PIN_MEMORY", "the WSL2 pin-memory invariant"),
]

# The modified-image class (a yml carrying the marker below) does not run a
# stock vllm/vllm-openai image: it runs a locally built image FROM a
# digest-pinned vendor base (the community 2x3090 stack case). Such a tier
# cannot carry the stock-image literal, and its wrapper owns the parsers -
# so the chat-template requirements do not apply. Everything else still does.
MODIFIED_IMAGE_MARKER = "provenance-class: modified-image"
MODIFIED_IMAGE_DROP = {
    "the image pin (literal, the 0.29.0 anchor)",
    "chat template knob",
    "chat template flag",
    "templates mount",
}
MODIFIED_IMAGE_EXTRA = [
    (r"image: \$\{VLLM_IMAGE:-[A-Za-z0-9._/-]+:locked\}",
     "the locked image pin (the modified-image class)"),
    (r"sha256:[0-9a-f]{40,64}", "the vendor base digest pin"),
]


def die(msg):
    print(f"FAIL: {msg}")
    sys.exit(1)


def read_lines(path):
    with open(path, "r", encoding="utf-8", newline="") as f:
        return f.read().splitlines()


def write_lines(path, lines):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


def parse_table(path):
    ops = []
    cur = None
    for i, line in enumerate(read_lines(path), 1):
        if line in ("REPLACE", "INSERT_AFTER"):
            cur = {"op": line, "lines": [], "at": i}
            ops.append(cur)
        elif line == "---":
            if cur is None:
                die(f"{path}:{i}: --- with no open block")
            if not cur["lines"]:
                die(f"{path}:{cur['at']}: empty {cur['op']} block")
            cur = None
        else:
            if cur is None:
                die(f"{path}:{i}: line outside any block")
            cur["lines"].append(line)
    if cur is not None:
        die(f"{path}: final block not terminated with ---")
    return ops


def cmd_build(a):
    try:
        src = read_lines(a.source)
        hdr = read_lines(a.header)
    except OSError as e:
        die(f"cannot read: {e}")
    if not hdr or hdr[-1] != SENTINEL:
        die(f"header {a.header} must end with the sentinel line")
    body = list(src)
    for op in parse_table(a.subst):
        name = op["lines"][0]
        n = body.count(name)
        if n != 1:
            die(f"{a.subst}: {op['op']} line {name!r} occurs {n}x (need exactly 1)")
        i = body.index(name)
        if op["op"] == "REPLACE":
            body[i] = op["lines"][1] if len(op["lines"]) == 2 else op["lines"][1]
            if len(op["lines"]) > 2:
                body[i + 1 : i + 1] = op["lines"][2:]
        else:  # INSERT_AFTER
            body[i + 1 : i + 1] = op["lines"][1:]
    write_lines(a.out, hdr + body)
    print(f"ok  built {a.out} ({len(hdr)} header lines + {len(body)} body lines)")


def load_manifest(path):
    pats = []
    for i, line in enumerate(read_lines(path), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        kind, _, pat = s.partition(" ")
        if kind not in ("DEL", "ADD"):
            die(f"{path}:{i}: pattern line must start with DEL or ADD")
        try:
            pats.append((kind, re.compile(pat)))
        except re.error as e:
            die(f"{path}:{i}: bad regex {pat!r}: {e}")
    if not pats:
        die(f"{path}: no patterns")
    return pats


def cmd_check(a):
    yml = read_lines(a.yml)
    try:
        idx = yml.index(SENTINEL)
    except ValueError:
        die(f"{a.yml}: sentinel line not found")
    body = yml[idx + 1 :]
    src = read_lines(a.source)
    pats = load_manifest(a.manifest)
    counts = [(k, p, 0) for k, p in pats]
    sm = difflib.SequenceMatcher(None, src, body, autojunk=False)
    bad = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag in ("delete", "replace"):
            for line in src[i1:i2]:
                if not any(k == "DEL" and p.search(line) for k, p, _ in counts):
                    bad.append(("DEL", line))
        if tag in ("insert", "replace"):
            for line in body[j1:j2]:
                if not any(k == "ADD" and p.search(line) for k, p, _ in counts):
                    bad.append(("ADD", line))
    for kind, pat, _ in counts:
        lines = body if kind == "ADD" else src
        n = sum(1 for line in lines if pat.search(line))
        counts[counts.index((kind, pat, _))] = (kind, pat, n)
    if bad:
        for kind, line in bad:
            print(f"  unmatched {kind}: {line}")
        die(f"undocumented change(s) in {a.yml} body vs source")
    unused = [(k, p) for k, p, n in counts if n == 0]
    if unused:
        for k, p in unused:
            print(f"  unused pattern: {k} {p.pattern}")
        die("manifest pattern(s) matched nothing — drift between manifest and reality")
    print(f"ok  {a.yml}: body diffs against source exactly as the manifest documents")
    for k, p, n in counts:
        print(f"  {k} x{n}: {p.pattern}")

def cmd_lint(a):
    lines = read_lines(a.yml)
    try:
        idx = lines.index(SENTINEL)
    except ValueError:
        die(f"{a.yml}: sentinel line not found")
    # FORBIDDEN is a body-only check over NON-COMMENT lines: the header may
    # name in-place artifacts (its job is provenance), and the body may carry
    # the source's own comments verbatim (byte-fidelity). Residue that matters
    # is an active line — a mount, an env var, a flag — still pointing at the
    # old layout.
    body = lines[idx + 1 :]
    bad = []
    for i, line in enumerate(body, idx + 2):
        if line.lstrip().startswith("#"):
            continue
        for pat, why in FORBIDDEN:
            if re.search(pat, line):
                bad.append(f"  line {i} ({why}): {line}")
    text = "\n".join(lines)
    modified = MODIFIED_IMAGE_MARKER in text
    req = ([r for r in REQUIRED if r[1] not in MODIFIED_IMAGE_DROP]
           + MODIFIED_IMAGE_EXTRA) if modified else REQUIRED
    for pat, what in req:
        if not re.search(pat, text, re.M):
            bad.append(f"  missing: {what} ({pat})")
    for i in range(len(body) - 1):
        if body[i].strip() == "- --chat-template" and not body[i + 1].strip().startswith("- /templates/"):
            bad.append(f"  line {idx + 2 + i}: --chat-template not followed by a /templates/ value")
            break
    if bad:
        print("\n".join(bad))
        die(f"{a.yml} lint failed")
    print(f"ok  {a.yml}: lint clean (sentinel, no in-place residue, invariants present)")


def cmd_types(a):
    """The YAML-type gate the provenance check cannot do: compose requires
    every command/entrypoint/environment scalar to be a *string* — an
    unquoted number (a bare `229376` in a command list) parses as an int and
    fails compose validation at boot with 'command.N must be a string'."""
    import re as _re
    import yaml
    raw = "\n".join(read_lines(a.yml))
    # compose interpolates ${VAR} / ${VAR:-default} against its own
    # environment in the raw text BEFORE the YAML parse; mimic that so the
    # parse below sees the scalars compose will actually build.
    raw = _re.sub(r"\$\{[^}]*\}", "X", raw)
    doc = yaml.safe_load(raw) or {}
    bad = []
    for name, svc in (doc.get("services") or {}).items():
        for key in ("command", "entrypoint", "environment", "env_file"):
            v = svc.get(key)
            if isinstance(v, list):
                for i, item in enumerate(v):
                    if not isinstance(item, str):
                        bad.append(
                            f"{name}.{key}[{i}] is {type(item).__name__}: {item!r}"
                        )
        if isinstance(svc.get("environment"), dict):
            for k, item in svc["environment"].items():
                if not isinstance(item, str):
                    bad.append(
                        f"{name}.environment[{k!r}] is {type(item).__name__}: {item!r}"
                    )
    if bad:
        for b in bad:
            print(f"FAIL: {b}  (quote it: a bare number/bool here is not a string)")
        sys.exit(1)
    print(f"ok  {a.yml}: every command/entrypoint/environment scalar is a string")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("build")
    p.add_argument("--source", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--header", required=True)
    p.add_argument("--subst", required=True)
    p.set_defaults(fn=cmd_build)
    p = sub.add_parser("check")
    p.add_argument("--yml", required=True)
    p.add_argument("--source", required=True)
    p.add_argument("--manifest", required=True)
    p.set_defaults(fn=cmd_check)
    p = sub.add_parser("lint")
    p.add_argument("--yml", required=True)
    p.set_defaults(fn=cmd_lint)
    p = sub.add_parser("types")
    p.add_argument("--yml", required=True)
    p.set_defaults(fn=cmd_types)
    a = ap.parse_args()
    try:
        a.fn(a)
    except SystemExit:
        raise
    except Exception as e:
        die(f"{type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
