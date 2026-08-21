# End-to-end example: patched Pkg + RegistrySnapshots.jl, fully isolated from your real depot.
#
# Requires Julia nightly and the patched Pkg fork linked from the README, e.g.:
#   juliaup add nightly
#   julia +nightly examples/end_to_end.jl
using Pkg

function timed(f, label)
    print(label, "... ")
    flush(stdout)
    t = @elapsed f()
    println("done ($(round(t; digits = 1))s)")
    return nothing
end

# Reused across runs (rather than `mktempdir()`) so the depot and the Pkg fork checkout keep
# their compiled caches: a fresh path each run gives every package, including the sizeable
# forked Pkg itself, a cold precompile.
scratch = joinpath(@__DIR__, "..", "scratch", "e2e")
depot = joinpath(scratch, "depot")
project = joinpath(scratch, "project")
pkg_checkout = joinpath(scratch, "pkg-fork")
mkpath(depot)
mkpath(project)

# Pkg's README on developing Pkg: clone the fork and start Julia with `--project`
# pointed at the checkout, so `using Pkg` resolves to it directly (self-referential project
# load by name/uuid match) instead of the stdlib copy.
timed("Updating Pkg fork checkout") do
    if isdir(joinpath(pkg_checkout, ".git"))
        run(`git -C $pkg_checkout fetch --quiet --depth 1 origin explicit-registries`)
        run(`git -C $pkg_checkout reset --quiet --hard FETCH_HEAD`)
    else
        run(`git clone --quiet --depth 1 --branch explicit-registries https://github.com/BjarkeHautop/Pkg.jl $pkg_checkout`)
    end
end

timed("Setting up project (develop + instantiate)") do
    pushfirst!(DEPOT_PATH, depot)
    try
        Pkg.activate(project)

        # This checkout of RegistrySnapshots.jl.
        Pkg.develop(path = joinpath(@__DIR__, ".."))

        Pkg.instantiate()
    finally
        popfirst!(DEPOT_PATH)
    end
end

# Stack the Pkg checkout ahead of `project` on the load path: `using Pkg` resolves against
# the checkout's own Project.toml (name/uuid match, self-referential load), and everything
# else (RegistrySnapshots, its `using Pkg`, Example) resolves against `project` as usual.
sep = Sys.iswindows() ? ';' : ':'
child_load_path = join([pkg_checkout, project, "@stdlib"], sep)
child_depot_path = join([depot; DEPOT_PATH], sep)

timed("Running RegistrySnapshots.add in child process") do
    run(
        setenv(
            `$(Base.julia_cmd()) --startup-file=no -e "
                using RegistrySnapshots
                RegistrySnapshots.add(\"Example\"; cutoff = \"30 days\")
                using Pkg
                Pkg.status()
            "`,
            "JULIA_LOAD_PATH" => child_load_path,
            "JULIA_DEPOT_PATH" => child_depot_path,
        ),
    )
end
