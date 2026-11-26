# F12-Q: companion transport ownership checkpoints

Status: prerequisite only. The Android plugin is **not yet server-free**. No lifecycle
hook uses the new position queue and no legacy queue or adapter file has been removed.
This work does not change the shipped feature matrix or enable a second writer.

## Reuse and scope

The existing library UI boundary (`android/koreader/orbit.koplugin/ko/library.lua:134`)
already dispatches neutral explicit position commands. The companion serial worker
(`android/companion/app/src/main/java/net/fledgewing/orbitcompanion/LibraryAccount.kt:42`)
and `ServerAdapter.position` remain the intended command path. The new
`ProgressOutbox` reuses the existing `Sql.transaction` port and `LuaValue` codec rather
than introducing another persistence/transport stack. It has not been connected to
that worker: the cutover must first establish the position policy and sole writer.

The prerequisite provides immutable FIFO position intents, commit before delivery,
acknowledgment after success and bounded retries. Every row carries its adapter and
opaque sync account namespace. Catalog ownership is insufficient because directly
entered sync and acquisition logins may belong to different users. Sign-out or an
account change retains old rows without sending them with another account's credentials.
Capture timestamps survive retries; a crash after server delivery and before local
acknowledgment may replay the same immutable intent. No exactly-once guarantee is claimed.

There are at most 1,000 pending rows across all accounts. A drain reads at most 24;
each position is at most 4,096 bytes and each encoded row at most 16 KiB. Capacity
failure retains existing work. Unknown extra inputs are not persisted, so credentials
cannot enter the queue through an unreviewed command field. These are worker limits,
not screen budgets. Every screen/widget retains its declared `logic/budgets.lua`
budget: no render network or subprocesses, at most one batched companion round trip
per Home paint, and at most 16 KiB per widget. Runtime integration must log a timing
span for each command/drain; host timings are not device acceptance.

## Migration evidence and remaining work

Pinned upstream `bookorbit` at `c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7` stores
five independently acknowledged phases: match, stats, annotations, state and progress
(`koreader-plugin/bookorbit.koplugin/bookorbit_lifecycle_outbox.lua:33`). Metadata
generations reference separate immutable payload generations; the loader validates
the entry ID, digest and payload before attaching its snapshot (`:183–211`).
The request preserves the capture timestamp (`bookorbit_api.lua:582–591`).

The remaining cutover must:

- Quiesce the old writer and import complete, unacknowledged lifecycle snapshots,
  including metadata/payload generation fallback, account provenance and every phase.
  Commit an import checkpoint before acknowledging or retiring source files. Test crashes
  at both boundaries. The position queue does not consume these files.
- Move the position policy and durable per-book marker/override/decline state behind the
  sole companion sync owner. Preserve every shared OrbiSmart fixture, including rereads,
  resets and behind-hold; keep the one-draw consent UI in the reader.
- Move cover acquisition and the remaining catalog, mirror, copies, recommendations
  and end-of-book operations onto neutral commands/snapshots using the existing workers.
- Replace lifecycle/middleware callers, remove the Lua server adapters, and strengthen
  the boundary guard without compatibility consumers or adapter exemptions for plugin Lua.
- Exercise the plugin end to end against a toy companion adapter. Only after those
  checks pass can backend-independence documentation say the plugin is server-free.

Xteink remains deferred under the maintainer's Android-first authorization. No release,
device operation, source-queue deletion or default flip is part of this prerequisite.
