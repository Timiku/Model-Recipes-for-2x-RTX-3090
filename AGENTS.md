# AGENTS.md — Model Recipes for 2x RTX 3090

Agent-facing notes for this tree: the live models, their recipes, and the shared boot machinery. One model folder per model, one backend subfolder per serving backend (`vllm/`, `llamacpp/`). The tree is self-contained: everything a box needs to install and run the models lives here.

## The one rule

**The Windows tree is the only source; the WSL side holds runtime state only.** Each tier is two files, both on the Windows side and read in place at boot: a **package template** (`vllm/package/<tier>.yml`, the compose project, a full default) and a **machine .env** (`vllm/<tier>.env`, beside the bats, the per-box overrides — plain docker compose .env format). The up-script passes it once (`--env-file <tier>.env -f <package yml>`) and sources the same file into the shell so the template's `${VAR:-default}` forms interpolate; compose's interpolation and the shell always agree because they read the same file. There is no mirror and no sync step. The WSL side holds exactly one folder per model — `~/model-recipes-rt/<model>/` — and only runtime state: the JIT cache and the boot log.

## Layout

- `<model>/` — one folder per model. Opens with a slim `MODEL.md` (the model card: tiers, ports, knobs, headline numbers).
- `vllm/package/` — the package templates: one compose yml per tier (`<tier>.yml`, provenance header + delta list) — the full default. This is the file the provenance gate diffs against `baseline/`, and the one a package update touches.
- `vllm/<tier>.env` — the machine .env, one per tier, beside its `start-<tier>.bat`: the box's overrides (device pair, bind, the max-ctx / concurrency shape, `WEIGHTS_DIR`). The wizard owns these (keep-or-reset on update); they are never reset by a reinstall and sit outside the provenance gate.
- `vllm/` (model level) — the bats (`install` / `start-*` / `stop` / `uninstall` / `bench` / `firewall`), the machine deltas, `vllm-patches/` (the patch bundles a yml's entrypoint applies at boot; vendored verbatim, arch-specific — present where an entrypoint applies patches), and `scripts/` (the boot-time helpers the ymls mount).
- `vllm/baseline/` — the stock 0.29.0 body per tier (the provenance anchor); `vllm/deltas/<tier>.txt` — the re-derived diff the gate checks the template against.
- `llamacpp/` — the light shape: one `RECIPE.md` card (the launch args, a link to the backend location, the measured line).
- `_shared/scripts/` — the model-agnostic machinery the bats call into: the prerequisite preflight, the runtime-area staging, the image and weights stages, the boot/stop/verdict brains (`up.sh` / `down.sh` / `serve.sh` / `verdict.sh`), the wizard's machine-.env readers/writers (`mcfg-get.ps1` / `mcfg-set.ps1`), the watchdog, and the yml provenance gate.
- `~/model-recipes-rt/<model>/` (WSL, not in this tree) — the vLLM runtime area. The only WSL-side trace of this project.

## Guardrails

- **The provenance gate is the contract.** `_shared/scripts/yml-provenance.py` checks every package yml against its baseline and delta manifest (check + lint; 10 tiers, all green). Run it before committing anything that touches a package yml, baseline, or delta. A failing gate means drift — fix the source of the drift, never the manifest by hand unless the change is real and documented.
- **Yml discipline:** each yml's provenance header lists its local deltas; the rest of the file stays byte-identical to the proven source. New deltas get a header line first. The `container_name` stays a literal in the yml — the up-script derives name, port, and cards from it.
- **vLLM boot invariants:** each yml names its own container literal (the qwen `qwen-27b-*` family, the gemma `gemma-serve*` pair, the flash-next `qwen38-flashnext-*` pair); the device pin is the `0,1` + `PCI_BUS_ID` default (the common two-card layout), overridable via `DEVICE_PAIR` in the tier's machine .env — load bearing.
- **Tiers are mutually exclusive** (the vLLM tiers need both cards); the up-script preflight refuses when a card holds >4 GB. One model at a time.
- **Uninstall deletes machine-owned paths only**: its own `~/model-recipes-rt/<model>/` and the docker image it pulled (pruned only when no other model still references the tag; a user-set `WEIGHTS_DIR` in a machine .env is user property, however the rest of uninstall runs).
- **Cache policy:** no seed copy of JIT caches — first boot re-JITs; that is a decision, not a gap.
- **This tree ships live tiers only.** Staging, A/B variants, and experimental work belong outside it (in the private dev tree) and enter only when they have their full machinery and pass the gate.

## Making a change

Edit the file, boot the tier, verify the port answers, commit. A backend-line move (the community slug or the image line moves) starts at the upstream source: re-diff the package yml against the new baseline, update the delta manifest, re-run the gate, then boot-verify.

## Environment scars (this box class)

- **`wsl -lc '...'` preparser eats `$VAR`s** in the single-quoted command — logic goes in a script file, run that.
- **WSL→Windows interop flaps** (binfmt table wipes; "Exec format error") — never build flows on it.
- **Native shell eats backslashes in arguments** — forward-slash paths.
- **Probe containers:** `docker run --rm --entrypoint bash -v <dir>:/probe:ro vllm/vllm-openai:<tag> -c '...'` (the default entrypoint is the vllm CLI).
- **Booting a tier is a user action** (the bats); an agent verifies from the outside (ports, docker, nvidia-smi) and never boots a tier as a side effect of verification.
