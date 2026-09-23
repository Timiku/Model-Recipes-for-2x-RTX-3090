# ===========================================================================
# MODEL-RECIPES :: qwen3.8-flash-next / vllm ::
# Dockerfile (model-level build context: this vllm/ folder)
#
# Provenance
#   source    the community stack's own build: docker/Dockerfile of
#              DominikBucko/qwen38-flash-next-2x3090 at the tree pin
#              (the verbatim copy: baseline/upstream/Dockerfile)
#   delta     LOCAL - the changes vs the verbatim file: the COPY paths
#              re-pointed from the community repo layout to this
#              model-recipes context (the overlay + installer from
#              vllm-patches/ - the model-level overlay home - the wrapper,
#              the hot-cache rankings (the
#              vllm/ root) and the profile env (baseline/upstream/)), plus
#              one added COPY (the local arm probe; see the role list below).
#              09-16: the vision-variant wrapper COPY is gone - the tower
#              merged into the single wrapper (serve-container.sh, delta
#              noted there).
#              a pycache scrub of the copied overlay (a local run of the
#              installer or a compiler leaves __pycache__ the sha guard
#              rejects - the build stays clean without touching the source
#              tree)
#              Everything else (the base, the pip install, the overlay
#              install, the WORKDIR, the ENTRYPOINT) is verbatim.
#   base      vllm/vllm-openai:qwen38-flash-next@sha256:fc120ece
#              0a388cc0aa1caad4a9f1cd92113484ab7ec2fd0efadd62585be05bf8
#              (the vendor-published line; upstream/repro.lock.json)
#   re-home    2026-09-13, Phase 4: the COPY sources re-pointed to the
#              two-tier layout (patches/ -> vllm-patches/, the recipe
#              folder -> the vllm/ root + baseline/upstream/). No build
#              change: same base, same pip line, same overlay, same
#              ENTRYPOINT.
#   role      bakes in what the vendor image alone does not carry:
#                - humming-kernels 0.1.12 (the MoE backend the wrapper
#                  selects: --moe-backend humming)
#                - the sha-guarded vLLM overlay re-install (a no-op
#                  against the vendor image's shipped files, a guard
#                  against base drift - the source's own wording)
#                - the serve wrapper as ENTRYPOINT: it turns the recipe's
#                  profile env into the full vllm flag set (TP=2, the PLE
#                  table -> the CPU offload worker, the UVA experts tier,
#                  the MTP speculative head, the vision tower loaded)
#                - the arm probe at /usr/local/bin/arm-probe.py (local; the
#                  WSL2 device re-arm guard the start bat runs in a
#                  throwaway container before the boot - see arm-probe.py)
#                docker build -t qwen38-flash-next-2x3090:locked \
#                    -f <mirror>/vllm/Dockerfile <mirror>/vllm
#              the tag is the community's own name; the yml's
#              VLLM_IMAGE knob overrides for other machines.
# ===========================================================================
FROM vllm/vllm-openai:qwen38-flash-next@sha256:fc120ece0a388cc0aa1caad4a9f1cd92113484ab7ec2fd0efadd62585be05bf8

RUN python3 -m pip install --no-cache-dir humming-kernels==0.1.12

COPY vllm-patches/install_overlay.py /opt/qwen38/runtime/install_overlay.py
COPY vllm-patches/vllm-overlay /opt/qwen38/runtime/vllm-overlay
RUN find /opt/qwen38/runtime/vllm-overlay -name __pycache__ -type d -exec rm -rf {} +
RUN python3 /opt/qwen38/runtime/install_overlay.py /opt/qwen38/runtime/vllm-overlay

COPY baseline/upstream/2x3090-128gb.env /opt/qwen38/configs/2x3090-128gb.env
COPY static_hot_cache_rankings.json /workspace/static_hot_cache_rankings.json
COPY serve-container.sh /usr/local/bin/qwen38-serve
COPY arm-probe.py /usr/local/bin/arm-probe.py
RUN chmod 0755 /usr/local/bin/qwen38-serve /usr/local/bin/arm-probe.py

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/qwen38-serve"]
