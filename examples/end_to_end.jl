# End-to-end example, fully isolated from your real depot.
using Pkg

function timed(f, label)
    print(label, "... ")
    flush(stdout)
    t = @elapsed f()
    println("done ($(round(t; digits = 1))s)")
    return nothing
end

# Reused across runs (rather than `mktempdir()`) so the depot keeps its compiled caches: a
# fresh path each run gives every package a cold precompile.
scratch = joinpath(@__DIR__, "..", "scratch", "e2e")
depot = joinpath(scratch, "depot")
project = joinpath(scratch, "project")
mkpath(depot)
mkpath(project)

# Left in place for the rest of the script, mirroring a real session: this is what starting
# Julia with `JULIA_DEPOT_PATH` set (see the README) does for you automatically. Stock
# `Pkg.develop`/`Pkg.instantiate` below have no `depot` keyword, so without this they'd act on
# the real depot regardless of what's passed to `RegistrySnapshots.add` later -- and popping it
# straight back off after just the `add` call would make the `Pkg.status()` below unable to
# see the scratch depot's package store, wrongly reporting Example as not downloaded.
pushfirst!(DEPOT_PATH, depot)

timed("Setting up project (develop + instantiate)") do
    Pkg.activate(project; io = devnull)
    Pkg.develop(path = joinpath(@__DIR__, ".."); io = devnull)
    Pkg.instantiate()
    return nothing
end

using RegistrySnapshots

timed("RegistrySnapshots.add(\"Example\"; cutoff = \"30 days\")") do
    RegistrySnapshots.add("Example"; cutoff = "30 days")
    return nothing
end

Pkg.status()
