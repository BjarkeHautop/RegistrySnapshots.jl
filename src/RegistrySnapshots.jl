"""
    RegistrySnapshots

Resolve packages against the General registry as it existed on an earlier day.

Julia registries carry no publication timestamps (`Versions.toml` records only a tree hash
and a yanked flag), so a cutoff cannot be applied by filtering versions. Instead the whole
registry is rolled back: a published index maps each day to the registry commit current at
the end of it, and that commit's registry is installed as the depot's live General registry.

```julia
using RegistrySnapshots
RegistrySnapshots.add("DataFrames"; cutoff = "7 days")   # or cutoff = Date(2026, 1, 1)
```

This works with stock Julia and stock Pkg: `checkout!` overwrites `<depot>/registries/General.{toml,tar.gz}`
in place. See [`restore!`](@ref) to go back to the live registry.
"""
module RegistrySnapshots

using Dates
using Pkg
using TOML
using Tar
import Downloads
using CodecZlib: GzipDecompressorStream, GzipCompressorStream

const DEFAULT_INDEX_URL = "https://raw.githubusercontent.com/BjarkeHautop/RegistrySnapshots.jl/index-data/index.toml"

const REGISTRY_UUID = "23338594-aafe-5451-b93e-139f81909106"

# General's default branch, fetched once per newly materialized snapshot to check for yanks
# that happened after the snapshot's own commit -- a `yanked = true` is written to
# `Versions.toml` only after the fact, so an old commit can never know about a yank that
# happened later, only the live registry can.
const LIVE_REF = "master"

"""
URL of the date-to-commit index. May also be a local path. Override it to use a privately
hosted index, or to work entirely offline.
"""
index_url() = get(ENV, "JULIA_REGISTRY_SNAPSHOT_INDEX", DEFAULT_INDEX_URL)

# The copy shipped with this package. It is only as fresh as the installed version, so it is
# a fallback for when the live index cannot be fetched, never the first choice.
bundled_index_path() = normpath(joinpath(@__DIR__, "..", "index.toml"))

# Every entry is for a day that has already ended, so the index is immutable for everything
# it already contains and one fetch per session is plenty.
const INDEX = Ref{Union{Nothing, Dict{String, Any}}}(nothing)

"""
    RegistrySnapshots.index(; refresh = false) -> Dict

The date-to-commit index, downloaded once per session.
"""
function index(; refresh::Bool = false)
    if !refresh && INDEX[] !== nothing
        return INDEX[]
    end
    url = index_url()
    # A local path is accepted too, so an index can be used without publishing it.
    parsed = if isfile(url)
        TOML.parsefile(url)
    else
        tmp = tempname()
        try
            Downloads.download(url, tmp)
            try
                TOML.parsefile(tmp)
            finally
                Base.rm(tmp, force = true)
            end
        catch err
            bundled = bundled_index_path()
            isfile(bundled) || error(
                "could not fetch the snapshot index from $url, and no bundled copy was " *
                    "found at $bundled\n$(sprint(showerror, err))"
            )
            @warn "Could not fetch the snapshot index; falling back to the copy bundled " *
                "with RegistrySnapshots, which only covers dates known when it was installed." url
            TOML.parsefile(bundled)
        end
    end
    INDEX[] = parsed
    return parsed
end

"""
    RegistrySnapshots.coverage() -> (first_date, last_date)

The range of days the index can resolve to.
"""
function coverage()
    dates = snapshot_dates(index())
    return first(dates), last(dates)
end

snapshot_dates(idx) = sort!([Date(d) for d in keys(idx["snapshots"]::Dict{String, Any})])

"""
    RegistrySnapshots.parse_cutoff(x) -> Date

Accepts a `Date`, a relative age such as `"7 days"` or `"2 weeks"`, or a date string.
"""
parse_cutoff(cutoff::Date) = cutoff
function parse_cutoff(str::AbstractString)
    str = strip(str)
    m = match(r"^(\d+)\s*(day|week)s?$"i, str)
    if m !== nothing
        n = parse(Int, m.captures[1])
        unit = lowercase(m.captures[2]) == "day" ? Day : Week
        return today() - unit(n)
    end
    parsed = tryparse(Date, str, dateformat"yyyy-mm-dd")
    parsed === nothing && error(
        "could not parse cutoff $(repr(String(str))); expected a relative age such as " *
            "\"7 days\" or \"2 weeks\", or a date such as \"2026-01-01\""
    )
    return parsed
end

# The snapshot for a cutoff is the newest one not after it, so a cutoff landing on a day the
# index has no entry for -- or on a day it has not recorded yet -- still resolves rather than
# failing on an off-by-a-day.
function resolve_date(cutoff::Date)
    idx = index()
    dates = snapshot_dates(idx)
    i = searchsortedlast(dates, cutoff)
    i == 0 && error(
        "no snapshot at or before $cutoff; the index only goes back to $(first(dates))"
    )
    date = dates[i]
    entry = idx["snapshots"][string(date)]::Dict{String, Any}
    return date, entry["commit"]::String, entry["tree"]::String
end

"""
A private cache of previously fetched commits, kept beside the depot's `registries`
directory rather than inside it so ordinary Pkg operations never see it. `checkout!` installs
one of these into `registries` explicitly; nothing here is picked up on its own.
"""
snapshots_dir(depot::AbstractString) = joinpath(depot, "registry_snapshots")

snapshot_dir(depot::AbstractString, commit::AbstractString) = joinpath(snapshots_dir(depot), commit)

# `<commit>/General.toml` is what Pkg calls a compressed registry: a small TOML pointing at
# the archive beside it, which Pkg reads entries out of without ever unpacking.
snapshot_toml(depot::AbstractString, commit::AbstractString) =
    joinpath(snapshot_dir(depot, commit), "General.toml")

# Derived data, several MB of it per snapshot, so keep backup tools out of it the same way
# Pkg does for the registry directory.
function create_cachedir_tag(dir::AbstractString)
    tag = joinpath(dir, "CACHEDIR.TAG")
    isfile(tag) && return
    mkpath(dir)
    write(
        tag,
        """
        Signature: 8a477f597d28d172789f06886806bc55
        # This file is a cache directory tag created by RegistrySnapshots.jl.
        # For information about cache directory tags see https://bford.info/cachedir/
        """
    )
    return
end

# Redrawn in place on one line, so it costs nothing when stderr isn't a terminal and doesn't
# spam a log file with one line per callback either.
function report_progress(label::AbstractString, total::Integer, now::Integer, shown::Ref{Float64})
    total == 0 && return
    pct = now / total
    (pct - shown[] < 0.01 && pct < 1.0) && return
    shown[] = pct
    width = 30
    filled = round(Int, pct * width)
    bar = "="^filled * " "^(width - filled)
    print(stderr, "\r$label [$bar] $(round(Int, pct * 100))%")
    pct >= 1.0 && println(stderr)
    flush(stderr)
    return
end

# Mirrors Tar.jl's own `rewrite` (`Tar.rewrite_tarball` in Tar/src/create.jl), except it
# drops the tarball's single top-level directory (`General-<commit>/`, which GitHub always
# nests archives under) while walking entries, instead of only filtering them -- `rewrite`'s
# public predicate can skip entries but cannot rename them, so it can't strip a prefix.
#
# Like `rewrite`, this never extracts anything to disk: `old_tar` is read once to record
# each entry's byte offset (buffering it into memory first via `check_rewrite_old_tarball` if
# it isn't seekable, e.g. a decompression stream), then seeked back into per entry to copy
# data straight into `new_tar`. On Windows especially, extracting the registry's many
# thousands of small files to disk and re-archiving them from there (the previous approach)
# was the dominant cost of a first fetch -- an order of magnitude slower than the download.
#
# This relies on a handful of unexported Tar internals (`read_tarball`, `write_tarball`,
# `Header`, `skip_data`, `true_predicate`, `check_rewrite_old_tarball`) that back that same
# public `rewrite`/`extract`/`create` API and have been stable for years, but carry no semver
# guarantee the way Tar's documented API does.
function strip_top_level_prefix(old_tar::IO, new_tar::IO, commit::AbstractString)
    old_tar = Tar.check_rewrite_old_tarball(old_tar)
    tree = Dict{String, Any}()
    Tar.read_tarball(Tar.true_predicate, old_tar) do hdr, parts
        parts = parts[2:end] # drop the leading `General-<commit>` component
        if isempty(parts)
            Tar.skip_data(old_tar, hdr.size)
            return
        end
        node = tree
        name = pop!(parts)
        for part in parts
            node′ = get(node, part, nothing)
            if !(node′ isa Dict)
                node′ = node[part] = Dict{String, Any}()
            end
            node = node′
        end
        if hdr.type == :directory
            get(node, name, nothing) isa Dict || (node[name] = Dict{String, Any}())
        else
            node[name] = (hdr, position(old_tar))
        end
        Tar.skip_data(old_tar, hdr.size)
    end
    haskey(tree, "Registry.toml") || error("no `Registry.toml` in the snapshot for $commit")
    Tar.write_tarball(new_tar, tree) do node, tar_path
        if node isa Dict
            Tar.Header(tar_path, :directory, 0o755, 0, ""), node
        else
            hdr, pos = node
            Tar.Header(hdr; path = tar_path), (old_tar, pos)
        end
    end
    return new_tar
end

# Scans the live registry tarball for every `Versions.toml` that currently has at least one
# `yanked = true` entry. Costs one full registry
# download (same size as a snapshot fetch), so it is only worth paying once per newly
# materialized snapshot.
function fetch_yanked_versions(tarball_url::AbstractString, ref::AbstractString)
    yanked = Dict{String, Set{String}}()
    raw = tempname()
    try
        shown = Ref(0.0)
        Downloads.download(
            "$tarball_url/$ref", raw;
            progress = (total, now) -> report_progress("Checking for yanks", total, now, shown),
        )
        open(raw) do io
            tar = GzipDecompressorStream(io)
            Tar.read_tarball(Tar.true_predicate, tar) do hdr, parts
                parts = parts[2:end] # drop the leading `General-<ref>` component
                if length(parts) == 3 && parts[3] == "Versions.toml"
                    versions = TOML.parse(String(Tar.read_data(tar; size = hdr.size)))
                    entries = Set{String}(v for (v, meta) in versions if get(meta, "yanked", false) == true)
                    isempty(entries) || (yanked[join(parts, "/")] = entries)
                else
                    Tar.skip_data(tar, hdr.size)
                end
            end
        end
    finally
        Base.rm(raw; force = true)
    end
    return yanked
end

# Overlays `yanked = true` onto the `Versions.toml` entries named in `yanked` (paths relative
# to the registry root, as produced by `fetch_yanked_versions`), leaving every other file
# byte-for-byte untouched. Run only after `old_tar`'s content has already been verified
# against the index's recorded tree hash -- this deliberately changes bytes, so it must never
# be the thing that hash is checked against.
function apply_yanked_patch(old_tar::IO, new_tar::IO, yanked::Dict{String, Set{String}})
    old_tar = Tar.check_rewrite_old_tarball(old_tar)
    tree = Dict{String, Any}()
    Tar.read_tarball(Tar.true_predicate, old_tar) do hdr, parts
        node = tree
        name = pop!(parts)
        relpath = isempty(parts) ? name : join(vcat(parts, [name]), "/")
        for part in parts
            node′ = get(node, part, nothing)
            if !(node′ isa Dict)
                node′ = node[part] = Dict{String, Any}()
            end
            node = node′
        end
        if hdr.type == :directory
            get(node, name, nothing) isa Dict || (node[name] = Dict{String, Any}())
            Tar.skip_data(old_tar, hdr.size)
        elseif haskey(yanked, relpath)
            versions = TOML.parse(String(Tar.read_data(old_tar; size = hdr.size)))
            for v in yanked[relpath]
                haskey(versions, v) && (versions[v]["yanked"] = true)
            end
            node[name] = Vector{UInt8}(sprint(TOML.print, versions))
        else
            node[name] = (hdr, position(old_tar))
            Tar.skip_data(old_tar, hdr.size)
        end
    end
    Tar.write_tarball(new_tar, tree) do node, tar_path
        if node isa Dict
            Tar.Header(tar_path, :directory, 0o755, 0, ""), node
        elseif node isa Vector{UInt8}
            Tar.Header(tar_path, :file, 0o644, length(node), ""), IOBuffer(node)
        else
            hdr, pos = node
            Tar.Header(hdr; path = tar_path), (old_tar, pos)
        end
    end
    return new_tar
end

"""
Fetch the registry at `commit` and store it in Pkg's compressed registry format.

Unless `check_yanked` is `false`, also overlays `yanked = true` for any version the live
registry has yanked since `commit` -- otherwise a version yanked the day after the snapshot
was taken would be served forever, since a frozen historical commit can never learn about it.
"""
function materialize(
        commit::AbstractString, tree::AbstractString, tarball_url::AbstractString,
        dest::AbstractString; check_yanked::Bool = true
    )
    mkpath(dirname(dest))
    staging = dest * ".tmp"
    ispath(staging) && Base.rm(staging; recursive = true, force = true)
    mkpath(staging)
    return try
        raw = tempname()
        archive = joinpath(staging, "General.tar.gz")
        try
            shown = Ref(0.0)
            Downloads.download(
                "$tarball_url/$commit", raw;
                progress = (total, now) -> report_progress("Downloading $(commit[1:8])", total, now, shown),
            )
            open(raw) do io
                open(GzipCompressorStream, archive, "w") do gz_out
                    strip_top_level_prefix(GzipDecompressorStream(io), gz_out, commit)
                end
            end
        finally
            Base.rm(raw; force = true)
        end

        # The index records the commit's root tree, and the registry root is the repo root,
        # so a snapshot hashing to anything else was not built from what was promised. This
        # must run before any yank patch is applied below -- it verifies content against a
        # hash computed from the original, unmodified registry.
        got = open(archive) do io
            Tar.tree_hash(GzipDecompressorStream(io))
        end
        got == tree || error("snapshot $commit hashed to $got, but the index records $tree")

        # `final_tree` is what actually ends up on disk: `tree` itself, unless a yank patch
        # below changed bytes, in which case Pkg's own cache key must reflect that rather than
        # keep pointing at content that no longer matches.
        final_tree = tree
        if check_yanked
            yanked = fetch_yanked_versions(tarball_url, LIVE_REF)
            if !isempty(yanked)
                patched = archive * ".patched"
                open(archive) do io
                    open(GzipCompressorStream, patched, "w") do gz_out
                        apply_yanked_patch(GzipDecompressorStream(io), gz_out, yanked)
                    end
                end
                mv(patched, archive; force = true)
                final_tree = open(archive) do io
                    Tar.tree_hash(GzipDecompressorStream(io))
                end
            end
        end

        open(joinpath(staging, "General.toml"), "w") do io
            TOML.print(
                io, Dict(
                    "uuid" => REGISTRY_UUID,
                    "git-tree-sha1" => final_tree,
                    "path" => "General.tar.gz",
                )
            )
        end
        mv(staging, dest; force = true)
        dest
    finally
        ispath(staging) && Base.rm(staging; recursive = true, force = true)
    end
end

# Keep only the most recently used snapshots. Each one costs several MB, so a rolling
# `cutoff = "7 days"` would otherwise accumulate a new one every day forever.
function prune(depot::AbstractString, keep::Integer, protect::AbstractString)
    dir = snapshots_dir(depot)
    isdir(dir) || return String[]
    entries = filter(isdir, [joinpath(dir, e) for e in readdir(dir)])
    # Most recently touched first; `protect` is the snapshot just used.
    sort!(entries; by = mtime, rev = true)
    removed = String[]
    for (i, path) in enumerate(entries)
        (i <= keep || path == protect) && continue
        try
            Base.rm(path; recursive = true, force = true)
            push!(removed, basename(path))
        catch err
            @debug "could not prune cached snapshot" path exception = err
        end
    end
    return removed
end

registries_dir(depot::AbstractString) = joinpath(depot, "registries")

# Installs `src` (a materialized `<commit>/{General.toml,General.tar.gz}` pair) as the
# depot's live General registry. Each file is staged under a temp name in the same directory
# and then `mv`'d into place -- same-filesystem `mv` renames rather than copying, so the
# replace is a single atomic syscall per file: a process killed mid-swap leaves either the
# old pair or the new one on disk, never a half-written file.
function checkout_registry!(depot::AbstractString, src::AbstractString)
    dir = registries_dir(depot)
    mkpath(dir)

    # The pre-1.7 Pkg layout keeps an extracted `<depot>/registries/General/` directory
    # instead of a compressed pair. Left in place it would be discovered as a second copy of
    # the same UUID, so it's moved aside (once) rather than overwritten.
    extracted = joinpath(dir, "General")
    if isdir(extracted)
        backup = extracted * ".bak"
        Base.rm(backup; recursive = true, force = true)
        mv(extracted, backup)
        @warn "Found an extracted `General` registry; moved it aside" from = extracted to = backup
    end

    for name in ("General.toml", "General.tar.gz")
        dst = joinpath(dir, name)
        tmp = dst * ".tmp"
        cp(joinpath(src, name), tmp; force = true)
        mv(tmp, dst; force = true)
    end
    # Newer Pkg defaults to zstd (`General.tar.zst`); harmless once `General.toml` points at
    # our `.tar.gz` instead, but stale otherwise, so it's cleaned up rather than left orphaned.
    Base.rm(joinpath(dir, "General.tar.zst"); force = true)
    return nothing
end

"""
    RegistrySnapshots.checkout!(cutoff; depot = first(DEPOT_PATH), keep = 1, check_yanked = true) -> Date

Overwrite `depot`'s live General registry with the snapshot as of `cutoff` (a `Date`, a
relative age such as `"7 days"`, or a date string), and return the day actually checked out.

This replaces `<depot>/registries/General.toml` and `.tar.gz` in place. See
[`restore!`](@ref) to go back to the live registry.

The snapshot itself is fetched once per commit into `<depot>/registry_snapshots` and reused
compressed from then on, so repeated calls with the same cutoff cost nothing beyond the
file copy above. Only the `keep` most recently used cached commits are retained.

Unless `check_yanked` is `false`, versions yanked on the live registry after the snapshot's
commit are marked yanked in it too. This check only runs the first time a commit is fetched.
"""
function checkout!(
        cutoff; depot::AbstractString = first(DEPOT_PATH), keep::Integer = 1,
        check_yanked::Bool = true
    )
    date, commit, tree = resolve_date(parse_cutoff(cutoff))
    dir = snapshot_dir(depot, commit)
    toml = snapshot_toml(depot, commit)
    if !isfile(toml)
        @info "Fetching General registry as of $date ($(commit[1:8]))"
        create_cachedir_tag(snapshots_dir(depot))
        materialize(commit, tree, index()["tarball_url"]::String, dir; check_yanked)
        prune(depot, keep, dir)
    end
    checkout_registry!(depot, dir)
    return date
end

"""
    RegistrySnapshots.restore!(; depot = first(DEPOT_PATH))

Undo [`checkout!`](@ref): re-fetch the live General registry into `depot`, the same as
running `Pkg.Registry.update()` yourself. `depot` is temporarily added to `DEPOT_PATH` for
the call if it isn't already part of it.
"""
function restore!(; depot::AbstractString = first(DEPOT_PATH))
    inserted = !(depot in DEPOT_PATH)
    inserted && pushfirst!(DEPOT_PATH, depot)
    try
        Pkg.Registry.update()
    finally
        inserted && popfirst!(DEPOT_PATH)
    end
    return nothing
end

"""
    RegistrySnapshots.cached(; depot = first(DEPOT_PATH)) -> Vector{String}

The snapshot commits currently cached in `depot` (see [`checkout!`](@ref)); not the same as
which one, if any, is currently checked out into `depot`'s live registry.
"""
function cached(; depot::AbstractString = first(DEPOT_PATH))
    dir = snapshots_dir(depot)
    isdir(dir) || return String[]
    return sort!([basename(p) for p in readdir(dir; join = true) if isfile(joinpath(p, "General.toml"))])
end

"""
    RegistrySnapshots.gc(; depot = first(DEPOT_PATH), keep = 0)

Delete cached snapshots, keeping the `keep` most recently used. Does not touch whichever
registry is currently checked out into `depot`'s live registries directory.
"""
gc(; depot::AbstractString = first(DEPOT_PATH), keep::Integer = 0) = prune(depot, keep, "")

# The Pkg operations that consult a registry. Each takes the same arguments as its `Pkg`
# counterpart plus a `cutoff`, checks out that day's registry into `depot`, and then calls
# plain `Pkg.$f` -- no patched Pkg or special keyword needed, since by then `depot`'s registry
# genuinely is the snapshot.
const WRAPPED = (:add, :develop, :rm, :update, :pin, :free, :instantiate, :resolve, :status, :why)

for f in WRAPPED
    @eval begin
        """
            RegistrySnapshots.$($(string(f)))(args...; cutoff, kwargs...)

        As `Pkg.$($(string(f)))`, but first checking out the General registry as of `cutoff`
        into the depot (see [`checkout!`](@ref)).
        """
        function $f(
                args...; cutoff, depot::AbstractString = first(DEPOT_PATH), keep::Integer = 1,
                check_yanked::Bool = true, kwargs...
            )
            checkout!(cutoff; depot, keep, check_yanked)
            inserted = !(depot in DEPOT_PATH)
            inserted && pushfirst!(DEPOT_PATH, depot)
            try
                return Pkg.$f(args...; kwargs...)
            finally
                inserted && popfirst!(DEPOT_PATH)
            end
        end
    end
end

end # module
