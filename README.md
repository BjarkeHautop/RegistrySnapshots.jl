# RegistrySnapshots.jl

> [!NOTE]
> This branch requires a patched Pkg.jl and Julia nightly, in exchange for never touching your depot's live registry (see [What it does to your depot](#what-it-does-to-your-depot)). For a version that works with stock Julia and stock Pkg, by overwriting the depot's registry instead of passing a snapshot in per-call, see the [`main`](https://github.com/BjarkeHautop/RegistrySnapshots.jl/tree/main) branch.

Resolve Julia packages against the General registry as it existed on an earlier day. Requires a patched [Pkg.jl version](https://github.com/BjarkeHautop/Pkg.jl/tree/explicit-registries) and Julia nightly to function. Made with the usage of AI, and relies on internals of Tar.jl, so use at your own risk.

Why the patch: stock Pkg always resolves against whatever registry is installed in your depot, there's no per-call override. Without the patch, resolving against a snapshot would mean overwriting your live registry. The patch just adds a `registries` keyword so a snapshot can be passed in for one call, depot untouched.

To use it simply just use RegistrySnapshots whenever you would use Pkg:

```julia
using RegistrySnapshots
RegistrySnapshots.add("Example"; cutoff = "7 days")   # or cutoff = Date(2026, 1, 1)
```

Every Pkg operation that consults a registry has a wrapper here that takes the same arguments plus `cutoff`. They resolve against the snapshot for that day instead of whatever is installed in your depot.

A full example is shown in `/examples/end_to_end.jl` (which clones the patched Pkg.jl fork and installs Example from 30 days ago). To run it, clone this repo and run
```bash
julia +nightly examples/end_to_end.jl
```

## How it works

Julia registries carry no publication timestamps. `Versions.toml` records only a tree hash and a yanked flag, so a cutoff cannot be applied by filtering versions the way other tools do. Instead the registry is rolled back via a published index that maps each day to the General commit that was current at the end of it, and that commit's tree is fetched and resolved against directly, without ever touching your installed registry:

```
add("DataFrames"; cutoff = "7 days")
   -> today - 7 = 2026-08-14
   -> index lookup: 2026-08-14 = commit 862be195, tree 128729c9
   -> fetch codeload.github.com/JuliaRegistries/General/tar.gz/862be195
   -> cache as a compressed registry under <depot>/registry_snapshots/862be195/
   -> Pkg.add("DataFrames"; registries = [that snapshot])
```

### What it does to your depot

The live registry is never touched. The snapshot is kept in its own directory, `<depot>/registry_snapshots/<commit>/`, in the same compressed format Pkg uses for `<depot>/registries`, and passed to Pkg explicitly via the `registries` keyword for just that call.

### Cost

| | |
|---|---|
| index fetch | 30 KB, once per session |
| new snapshot | 11 MB download — same as a live registry update |
| yank check | another 11 MB download, once per new snapshot (see below) |
| repeated use of a cached day | instant, read straight from the compressed snapshot |
| disk | ~11 MB per cached snapshot (compressed, same format as a live registry) |

Only the `keep` most recent snapshots are retained per depot (default 1), so a rolling `cutoff = "7 days"` does not accumulate one per day.

Each new snapshot is a full tarball download, not an incremental one, since there's no git-style fetch of just the objects that changed since the last cached commit.

### Yanks

A frozen snapshot has an obvious problem: if a version gets yanked *after* the cutoff day, the snapshot has no way to know, and would happily keep resolving to it forever. To fix that, the first time a commit is fetched, `registry`/the wrappers also download the live registry to a temp file, scan it for `yanked = true` entries, and overlay those onto the snapshot. Pass `check_yanked = false` to skip this and save the extra download.

## API

| function | what it does |
|---|---|
| `add`, `develop`, `rm`, `update`, `pin`, `free`, `instantiate`, `resolve`, `status`, `why` | as the matching `Pkg.*` function, but resolved against the General registry as of `cutoff` |
| `RegistrySnapshots.registry(cutoff; depot, keep, check_yanked)` | the snapshot for `cutoff` as a `Pkg.Registry.RegistryInstance` — pass it yourself as `registries = [...]` to any other Pkg call |
| `RegistrySnapshots.cached(; depot)` | commits currently cached in `depot` |
| `RegistrySnapshots.gc(; depot, keep = 0)` | delete cached snapshots, keeping the `keep` most recently used |
| `RegistrySnapshots.coverage()` | the range of days the index can resolve to |

Every wrapper takes `cutoff` as a required keyword, plus optional `depot` (default `first(DEPOT_PATH)`), `keep` (default `1`, how many snapshots to retain in that depot's cache), and `check_yanked` (default `true`, see [Yanks](#yanks)). Everything else is forwarded straight to the underlying `Pkg` function.

`cutoff` accepts a `Date`, a relative age (`"7 days"`, `"2 weeks"`), or a date string (`"2026-01-01"`).

### Environment

Unlike main branch it never overwrites your other depot. `depot` only affects where snapshots are cached. If you'd still like that cache kept apart from your everyday depot, pass `depot = ...` explicitly, or start Julia with `JULIA_DEPOT_PATH` pointing at a separate depot.

`JULIA_REGISTRY_SNAPSHOT_INDEX` overrides the index location, and accepts a local path as well as a URL.

## The index

`index.toml` holds one entry per UTC day:

```toml
uuid = "23338594-aafe-5451-b93e-139f81909106"
tarball_url = "https://codeload.github.com/JuliaRegistries/General/tar.gz"

[snapshots]
"2026-08-13" = { commit = "862be195132c60fc414509221147a4819f3a72b5", tree = "128729c9a723454eb16ea455b00200333495fdd0" }
```

- `commit` — the last commit made on or before the **end** of that UTC day.
- `tree` — that commit's git tree hash, which is what the fetched tarball is verified against before it's cached.

Only completed UTC days are recorded, so every entry is immutable once written: a past day's last commit can never change. Lookups are therefore permanently cacheable and resolution is reproducible.

At roughly 140 bytes per day the file grows about 50 KB/year. It is fetched at runtime so it is always current; the copy shipped with the package is used only as an offline fallback.

### Regenerating

```
julia tools/generate_index.jl [--index PATH] [--repo PATH] [--first YYYY-MM-DD]
```

Reads the existing index, works out which days are missing, and fetches only enough history to cover them. Existing entries are never recomputed, and a run with nothing to add makes no network requests at all.

[`.github/workflows/update-index.yml`](https://github.com/BjarkeHautop/RegistrySnapshots.jl/blob/main/.github/workflows/update-index.yml) (defined on `main`, since scheduled workflows always run from the default branch) runs this daily at 12:00 UTC and commits the result to the [`index-data`](https://github.com/BjarkeHautop/RegistrySnapshots.jl/tree/index-data) branch if anything changed -- kept separate so the daily bot commits don't clutter either branch's history. The copy of `index.toml` checked in here is just a point-in-time snapshot, not kept current by that workflow.
