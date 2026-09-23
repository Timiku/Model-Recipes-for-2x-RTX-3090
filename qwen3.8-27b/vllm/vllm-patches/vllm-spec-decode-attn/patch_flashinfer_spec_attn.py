#!/usr/bin/env python3
"""
patch_flashinfer_spec_attn.py -- vllm-spec-decode-attn installer (vllm 0.29.0)

Applies, in place, three exact edits to vllm/v1/attention/backends/flashinfer.py:

  1. import the staged dispatch module (anchored on the first top-level class,
     so it is drift-proof against the import section);
  2. in build(): stash the raw vllm paged tensors (block_table / seq_lens /
     qo_indptr / qo_indptr_cpu) onto the FlashInferMetadata so the forward
     side can gather from them;
  3. in forward(): wrap the native FIPrefill run() so the spec-decode prefill
     is first offered to the dense dispatch; on decline it runs unchanged.

Marker-gated idempotent (re-run is a no-op). Hard-fails (exit 2) on any anchor
mismatch so a drifted vllm never boots with a half-applied patch.
"""
import py_compile
import re
import shutil
import sys
from pathlib import Path

MARKER = "vllm-spec-decode-attn"
BUNDLE = Path(__file__).resolve().parent


def fail(msg):
    print("  [spec-decode-attn] REFUSING TO CONTINUE: " + msg)
    sys.exit(2)


def main():
    try:
        import vllm  # noqa
        base = Path(vllm.__file__).parent
    except Exception as e:
        fail("cannot import vllm (%s); is the image pinned to 0.29.0?" % e)
    f = base / "v1" / "attention" / "backends" / "flashinfer.py"
    if not f.exists():
        fail("flashinfer.py not found at %s" % f)
    src = f.read_text()
    if MARKER in src:
        print("  [spec-decode-attn] already applied (marker present). done.")
        return

    # ---- 1. import: anchor on the first top-level class (drift-proof) ----
    cm = re.search(r"^\s*class \w+", src, re.M)
    if not cm:
        fail("no top-level class found for the import anchor; drifted?")
    import_line = "from vllm.v1.attention.ops import spec_decode_attn_dispatch\n"
    src = src[:cm.start()] + import_line + src[cm.start():]

    # ---- 2. build(): stash the raw paged tensors -------------------------
    m = re.search(r"[ \t]*attn_metadata = FlashInferMetadata\(", src)
    if not m:
        fail("build() FlashInferMetadata( anchor not found; drifted?")
    i = src.index("(", m.start())
    depth = 0
    close = None
    while i < len(src):
        c = src[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                close = i
                break
        i += 1
    if close is None:
        fail("could not balance FlashInferMetadata( constructor parens")
    j = close
    while j < len(src) and src[j] not in "\n":
        j += 1
    j += 1  # past the newline
    ind = "        "
    stash = (
        "\n" + ind + "attn_metadata._sd_block_table = block_table_tensor\n"
        + ind + "attn_metadata._sd_seq_lens = seq_lens\n"
        + ind + "attn_metadata._sd_qo_indptr = qo_indptr\n"
        + ind + "attn_metadata._sd_qo_indptr_cpu = qo_indptr_cpu\n"
        + ind + "attn_metadata._sd_page_size = page_size"
    )
    src = src[:j] + stash + src[j:]

    # ---- 3. forward(): wrap the native FIPrefill run (indent-tolerant) ---
    run_pat = re.compile(
        r"([ \t]+)prefill_wrapper\.run\(\s*\n"
        r"[ \t]+prefill_query,\s*\n"
        r"[ \t]+kv_cache_for_fi,\s*\n"
        r"[ \t]+q_scale=layer\._q_scale_float,\s*\n"
        r"[ \t]+k_scale=layer\._k_scale_float,\s*\n"
        r"[ \t]+v_scale=layer\._v_scale_float,\s*\n"
        r"[ \t]+out=out_prefill,\s*\n"
        r"[ \t]+kv_cache_sf=kv_cache_sf,\s*\n"
        r"[ \t]+\)",
        re.M)
    n = len(run_pat.findall(src))
    if n != 1:
        fail("native FIPrefill run anchor not unique (found %d); drifted?" % n)
    mm = run_pat.search(src)
    i0 = mm.group(1)      # original indent of the run(...) call
    a = i0 + "    "       # +4 (the if's suite / the call args)
    b = i0 + "        "   # +8 (the run call's args)
    guarded = (
        i0 + "if not spec_decode_attn_dispatch.spec_attn_maybe_run(\n"
        + a + "self,\n"
        + a + "attn_metadata,\n"
        + a + "prefill_query,\n"
        + a + "kv_cache_for_fi,\n"
        + a + "layer,\n"
        + a + "out_prefill,\n"
        + i0 + "):\n"
        + a + "prefill_wrapper.run(\n"
        + b + "prefill_query,\n"
        + b + "kv_cache_for_fi,\n"
        + b + "q_scale=layer._q_scale_float,\n"
        + b + "k_scale=layer._k_scale_float,\n"
        + b + "v_scale=layer._v_scale_float,\n"
        + b + "out=out_prefill,\n"
        + b + "kv_cache_sf=kv_cache_sf,\n"
        + a + ")"
    )
    src = src[:mm.start()] + guarded + src[mm.end():]

    # ---- 4. stage the dispatch module into vllm --------------------------
    ops = base / "v1" / "attention" / "ops"
    ops.mkdir(parents=True, exist_ok=True)
    src_mod = BUNDLE / "spec_decode_attn_dispatch.py"
    if not src_mod.exists():
        fail("dispatch module missing in bundle: %s" % src_mod)
    dst = ops / "spec_decode_attn_dispatch.py"
    shutil.copyfile(src_mod, dst)
    print("  [spec-decode-attn] staged dispatch -> %s" % dst)

    f.write_text(src)
    py_compile.compile(str(f), doraise=True)
    py_compile.compile(str(dst), doraise=True)
    print("  [spec-decode-attn] patched flashinfer.py (import + build-stash + "
          "native FIPrefill guard). done.")


if __name__ == "__main__":
    main()
