# AGENTS.md: Model Recipes for 2x RTX 3090

Notes for agents working in this tree. One folder per model, one subfolder per serving backend (`vllm/`, `llamacpp/`). Everything a machine needs to install and run the models is in the tree.

## Where config lives

The repo tree is the only source of config. Each tier is two tracked files, both read in place at boot:

- `vllm/package/<tier>.yml`: the compose file, holding every default as `${VAR:-default}`.
- `vllm/<tier>.env`: the shipping defaults, plain Docker compose `.env` format, next to the start scripts.

Plus one untracked layer: `vllm/<tier>.local.env` (gitignored) holds a box's machine truth - `DEVICE_PAIR`, `BIND_HOST`, `WEIGHTS_DIR`, per-box tuning. Local wins: every reader (`up.sh`, `down.sh`, `serve.sh`'s arm probe) goes through `_shared/scripts/tierenv.sh`, which emits `<tier>.env` then `<tier>.local.env`; later files win in both the shell source and the compose `--env-file` order. A shipping-default change to the tracked `.env` therefore cannot re-pin a box's hardware (the t34 lesson: cebb30d re-pinned the dev rig onto its display card through exactly this hole before the layer existed). The installer writes machine keys to the `.local.env`, never to the tracked file.

`up.sh` sources both files into its shell and passes both to compose (`--env-file <tier>.env --env-file <tier>.local.env -f package/<tier>.yml`), so the shell and compose always see the same values, in the same precedence order. There is no mirror and no sync step.

On Windows the tree sits on the Windows side and the WSL distro holds only runtime state, in `~/model-recipes-rt/<model>/`: the JIT cache, the boot log (`boot-failure.log`), the last boot's result (`boot-last-status`) and a memory trace (`commit-trace`). Native Linux uses the same folder under `$HOME`.

## Layout

| path | contents |
|---|---|
| `<model>/MODEL.md` | The model card: tiers, ports, settings, measured numbers. |
| `<model>/vllm/package/<tier>.yml` | Compose file per tier. A provenance header lists its local changes; the provenance gate diffs the rest against `baseline/`. |
| `<model>/vllm/<tier>.env` | Shipping defaults per tier. Tracked. Not covered by the provenance gate. |
| `<model>/vllm/<tier>.local.env` | Box machine truth (gitignored): the installer writes `DEVICE_PAIR`, `BIND_HOST` and `WEIGHTS_DIR` here; overrides the tracked `.env` key-by-key. Created on demand; never committed. |
| `<model>/vllm/*.bat`, `*.sh` | Entry scripts: `install`, `start-<tier>`, `stop`, `uninstall`, `bench`, `bench-parallel`, and `firewall` (Windows only). |
| `<model>/vllm/baseline/<tier>.yml` | The reference body the gate compares against: the pre-rebase body (v0.27.1 form for the 27B, v0.28.0 for Gemma; Flash-Next has its own upstream snapshot) with its `image:` line changed to v0.29.0. Several tiers share one baseline (e.g. the kvarn tiers diff against `nomtp.yml` or `superfast.yml`). |
| `<model>/vllm/deltas/<tier>.txt` | The allowed differences between baseline and package yml. |
| `<model>/vllm/vllm-patches/` | Patch bundles a yml's entrypoint applies at boot. Vendored verbatim, architecture-specific. |
| `<model>/vllm/scripts/` | Boot-time helpers the ymls mount. |
| `<model>/llamacpp/RECIPE.md` | A card for the llama.cpp path: launch arguments and measured results. No scripts. |
| `_shared/scripts/` | Model-independent machinery. `up.sh` (boot), `down.sh` (stop), `serve.sh` (arm probe + `up.sh` + log tail), `verdict.sh` (prints the last boot result), `install-core.sh` (install stages), `uninstall-core.sh`, `uninstall-all-core.sh`, `mcfg-get.ps1` / `mcfg-set.ps1` / `mcfg.sh` (read and write `.env` keys), `tierenv.sh` (the tier config precedence rule), `pickpair.bat` / `pickpair.sh` (GPU picker), `model-recipes-watchdog.ps1`, `yml-provenance.py` (the gate). |
| `_shared/scripts/gen-linux-entries.sh` | Generates every model's Linux entry scripts. The committed `.sh` files have since been hand-edited and no longer match the generator exactly: fix the generator and regenerate, don't patch outputs by hand. |
| `_shared/patches/vllm-kvarn-0290/` | The KVarN int4-KV bundle shared by the kvarn tiers. |

## Guardrails

- **Run the provenance gate** before committing anything that touches a package yml, a baseline or a delta:
  ```
  python3 _shared/scripts/yml-provenance.py check --yml <pkg.yml> --source <baseline.yml> --manifest <deltas.txt>
  python3 _shared/scripts/yml-provenance.py lint  --yml <pkg.yml>
  ```
  There are 12 tier ymls. All 12 pass `check` and all 12 pass `lint` (the Swift pair diffs against `baseline/mtp.yml` / `baseline/nomtp.yml`). A failing check means drift: fix the cause, and only edit the manifest when the change is real and documented.
- **Yml discipline.** Add a header line for a new change before making it. Everything outside the listed changes stays byte-identical to the baseline. Keep `container_name` a literal: `up.sh`, `serve.sh` and `down.sh` read the container name, and `up.sh` reads `--served-model-name`, straight from the yml with `sed`.
- **Container names.** Qwen 27B: `qwen-27b-*`. Gemma: `gemma-serve`, `gemma-serve-nomtp`. Flash-Next: `qwen38-flashnext-*`.
- **GPU pinning.** Every yml sets `CUDA_VISIBLE_DEVICES=${DEVICE_PAIR:-0,1}` with `CUDA_DEVICE_ORDER=PCI_BUS_ID`. The pin is load-bearing. 
- **One tier at a time.** Every vLLM tier needs both cards. `up.sh` refuses to boot when a pinned card holds more than 4000 MiB steadily for 12 checks 5 s apart, and waits up to `UP_CARD_DRAIN_TIMEOUT` (900 s) for a card that is still shedding memory.
- **Compose project names.** Every compose call carries `-p mr-<model>` (dots become dashes, e.g. `mr-qwen3-8-27b`); `up.sh`, `down.sh`, `install-core.sh`, `uninstall-core.sh` and `uninstall-all-core.sh` all build it the same way. A new compose site without `-p` reintroduces the shared-`package` hazard: one model's `down --remove-orphans` could remove another model's running container. The name-holder branches in `down.sh`/`uninstall-core.sh` still accept the legacy `package` project plus a tree-owned working_dir as a migration path.
- **Uninstall only deletes what the install created**: `~/model-recipes-rt/<model>/` and the image it pulled (only when no other model's yml names the same tag). A user-set `WEIGHTS_DIR` belongs to the user. No exceptions remain: the Linux `uninstall.sh` never touches the tree folder or weights, and `uninstall-all-core.sh` removes only the images the package ymls name.
- **JIT cache.** No pre-seeded cache ships. The first boot compiles from scratch, by design.
- **Only live tiers ship.** Staging, A/B variants and experiments stay in the private dev tree until they have their full scripts and pass the gate.
- **Build release archives with `git archive`** (not a folder zip): a folder copy rides along `_shared/scripts/__pycache__/*.pyc` and empty `logs/` folders; gitignore does not stop what has already been copied. `git archive -o model-recipes.zip HEAD` ships exactly the tracked tree.

## Making a change

Edit the file, boot the tier, check that the port answers, commit. When the upstream recipe or the image version moves, start from upstream: re-diff the package yml against the new baseline, update the delta manifest, re-run the gate, then boot and verify.

## Known environment problems (Windows + WSL2)

- **`wsl -lc '...'` expands `$VAR`s** inside the single-quoted command before it reaches bash. Put logic in a script file and run that.
- **WSL-to-Windows interop breaks intermittently** (the binfmt table gets wiped: "Exec format error"). Don't build flows that depend on it.
- **Backslashes get eaten** in arguments passed from Windows to WSL. Use forward slashes.
- **Probe containers:** `docker run --rm --entrypoint bash -v <dir>:/probe:ro vllm/vllm-openai:<tag> -c '...'`. The image's default entrypoint is the vLLM CLI.
- **Booting a tier is the user's call.** An agent verifies from outside (ports, `docker ps`, `nvidia-smi`) and never boots a tier as a side effect of checking something.
