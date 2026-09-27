# baseline/  --  the stock reference the provenance gate diffs against.

Each `<tier>.yml` here is the pre-rebase body of that tier's package yml
(the v0.28.0 form), with its `image:` line normalized to v0.29.0.
It is *body only* (no header, no sentinel) because `yml-provenance.py check`
reads the entire `--source` file as the reference. The sibling
`../deltas/<tier>.txt` documents every line the 0.29.0 rebase changed between
this body and `../package/<tier>.yml`, and the gate fails on any drift in
either direction. A future bump re-diffs the new package yml against this
baseline (or a re-snapshot of it) the same way.

