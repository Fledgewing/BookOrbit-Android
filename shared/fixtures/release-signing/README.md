# Release-signing fixtures

Signatures made with `tools/feed-keys/feed-keys` from throwaway keys (the private keys were
deleted), for every verifier to check against the same cases: the firmware's host tests and
the companion's unit tests. Each case in `cases.json` gives the inputs a verifier has after its
SHA-256 check (tag, asset name, SHA-256, the release's `SIGNATURES`, minimum serial) and
whether the update must be accepted. `other_root_public_key` is a root that signed nothing here.
