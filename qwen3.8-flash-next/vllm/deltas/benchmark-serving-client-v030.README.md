# benchmark_serving.py client patch - DominikBucko v0.3.0

Source: DominikBucko/qwen38-flash-next-2x3090, tag v0.3.0, `scripts/benchmark_serving.py` (their repo state at the v0.3.0 tag + the two patches below). The patched copy lives at `/opt/dbrepo/scripts/benchmark_serving.py` on the dev rig's WSL distro (root) - a shallow clone at that path, un-versioned otherwise; this patch is the durable record. Re-apply after any WSL reinstall.

The two deltas, and why:

1. `--base-url` is used WITHOUT the `/v1` suffix. Their client appends `/v1/completions` itself; feeding it a base that already ends in `/v1` produces `POST /v1/v1/completions` → 404.
2. `/tokenize` lives at the repo root in this image, not `/v1/tokenize`; the client's endpoint building was adjusted to match.

Operation scars (see also the bench-log entries t34/t35):

- Run the client in the FOREGROUND. Backgrounded `setsid nohup` launches from one-shot `wsl --` sessions die or hang silently with zero server-side requests; at least two experiment readings were polluted by this before it was named.
- Every client `timeout` must sit ABOVE the engine's 300 s `execute_model` RPC timeout, so a hang surfaces as a server-side `EngineDeadError` in `docker logs`, not as a silent client timeout. That ordering is what made t34 misreadable the first time.
- The corpus needs `repro.lock.json` beside the script's parent directory; the prompt style used throughout is `--prompt-style repo-chat`.
- Decode field in the result JSON: `api_observed_decode_estimate_tokens_per_second`.
