using RegistrySnapshots
using Dates
using Test
using Tar
using TOML
using CodecZlib: GzipCompressorStream, GzipDecompressorStream

const RS = RegistrySnapshots

# A stand-in for the published index, so the offline tests do not depend on the network or on
# which days happen to be recorded upstream.
const FAKE_INDEX = Dict{String, Any}(
    "uuid" => "23338594-aafe-5451-b93e-139f81909106",
    "repo" => "https://github.com/JuliaRegistries/General.git",
    "tarball_url" => "https://codeload.github.com/JuliaRegistries/General/tar.gz",
    "snapshots" => Dict{String, Any}(
        "2026-01-01" => Dict{String, Any}("commit" => "a"^40, "tree" => "b"^40),
        "2026-01-02" => Dict{String, Any}("commit" => "c"^40, "tree" => "d"^40),
        "2026-01-05" => Dict{String, Any}("commit" => "e"^40, "tree" => "f"^40),
    ),
)

withindex(f) = (RS.INDEX[] = FAKE_INDEX; try f() finally RS.INDEX[] = nothing end)

@testset "RegistrySnapshots" begin
    @testset "parse_cutoff" begin
        @test RS.parse_cutoff(Date(2026, 1, 1)) == Date(2026, 1, 1)
        @test RS.parse_cutoff("2026-01-01") == Date(2026, 1, 1)
        @test RS.parse_cutoff("7 days") == today() - Day(7)
        @test RS.parse_cutoff("1 day") == today() - Day(1)
        @test RS.parse_cutoff("2 weeks") == today() - Week(2)
        # Whitespace and case should not matter.
        @test RS.parse_cutoff("  7  Days ") == today() - Day(7)

        @test_throws ErrorException RS.parse_cutoff("garbage")
        @test_throws ErrorException RS.parse_cutoff("7 fortnights")
        @test_throws ErrorException RS.parse_cutoff("2026-13-01")
    end

    @testset "resolve_date" begin
        withindex() do
            # An exact hit resolves to itself.
            @test RS.resolve_date(Date(2026, 1, 2))[1] == Date(2026, 1, 2)
            @test RS.resolve_date(Date(2026, 1, 2))[2] == "c"^40

            # A day with no entry falls back to the newest earlier one, rather than failing.
            @test RS.resolve_date(Date(2026, 1, 4))[1] == Date(2026, 1, 2)

            # A cutoff past the end of the index clamps to the newest snapshot.
            @test RS.resolve_date(Date(2030, 1, 1))[1] == Date(2026, 1, 5)

            # A cutoff before coverage begins is an error, not a silent nearest match.
            @test_throws ErrorException RS.resolve_date(Date(2025, 1, 1))
        end
    end

    @testset "coverage" begin
        withindex() do
            @test RS.coverage() == (Date(2026, 1, 1), Date(2026, 1, 5))
        end
    end

    @testset "status without a pin" begin
        mktempdir() do depot
            # `cutoff` is required on every wrapper, `status` included.
            @test_throws UndefKeywordError RS.status(depot = depot)
        end
    end

    @testset "bundled index" begin
        # The bundled copy is the offline fallback, so it must be present and usable.
        path = RS.bundled_index_path()
        @test isfile(path)
        withenv("JULIA_REGISTRY_SNAPSHOT_INDEX" => path) do
            RS.INDEX[] = nothing
            try
                idx = RS.index()
                @test haskey(idx, "snapshots")
                @test idx["uuid"] == "23338594-aafe-5451-b93e-139f81909106"
                first_date, last_date = RS.coverage()
                @test first_date <= last_date
                # Every recorded day must resolve to a full-length commit hash.
                date, commit, tree = RS.resolve_date(last_date)
                @test date == last_date
                @test length(commit) == 40
                @test length(tree) == 40
            finally
                RS.INDEX[] = nothing
            end
        end
    end

    @testset "index url override" begin
        withenv("JULIA_REGISTRY_SNAPSHOT_INDEX" => "https://example.invalid/index.toml") do
            @test RS.index_url() == "https://example.invalid/index.toml"
        end
        withenv("JULIA_REGISTRY_SNAPSHOT_INDEX" => nothing) do
            @test RS.index_url() == RS.DEFAULT_INDEX_URL
        end
    end

    @testset "yank patching" begin
        # Builds a `General-<commit>/` tree shaped like a GitHub codeload tarball: one package
        # (`DataFrames`) whose 1.1.0 is yanked only in the "live" copy, plus an unrelated
        # package that must survive completely untouched.
        function build_registry(root::String, commit::String; yanked_112::Bool)
            top = joinpath(root, "General-$commit")
            mkpath(joinpath(top, "D", "DataFrames"))
            write(joinpath(top, "Registry.toml"), "name = \"General\"\n")

            versions = Dict{String, Any}(
                "1.0.0" => Dict{String, Any}("git-tree-sha1" => "b"^40),
                "1.1.0" => Dict{String, Any}("git-tree-sha1" => "c"^40),
            )
            yanked_112 && (versions["1.1.0"]["yanked"] = true)
            open(io -> TOML.print(io, versions), joinpath(top, "D", "DataFrames", "Versions.toml"), "w")

            mkpath(joinpath(top, "E", "Example"))
            write(
                joinpath(top, "E", "Example", "Versions.toml"),
                sprint(TOML.print, Dict{String, Any}("0.1.0" => Dict{String, Any}("git-tree-sha1" => "d"^40))),
            )
            return top
        end

        tar_gz(root::String, dest::String) = open(GzipCompressorStream, dest, "w") do io
            Tar.create(root, io)
        end

        # Reads a single `Versions.toml` back out of a compressed snapshot archive, the same
        # way Pkg would, without extracting anything else.
        function read_versions(archive::String, relpath::String)
            open(archive) do io
                tar = GzipDecompressorStream(io)
                found = Ref{Union{Nothing, Dict{String, Any}}}(nothing)
                Tar.read_tarball(Tar.true_predicate, tar) do hdr, parts
                    if join(parts, "/") == relpath
                        found[] = TOML.parse(String(Tar.read_data(tar; size = hdr.size)))
                    else
                        Tar.skip_data(tar, hdr.size)
                    end
                end
                return found[]
            end
        end

        mktempdir() do work
            commit = "a"^40
            srcdir = joinpath(work, "src")
            mkpath(srcdir)

            # The historical snapshot: 1.1.0 not yanked yet, named exactly `<commit>` so
            # `materialize` finds it at `"$tarball_url/$commit"`.
            old_root = joinpath(work, "old")
            old_top = build_registry(old_root, commit; yanked_112 = false)
            tar_gz(old_root, joinpath(srcdir, commit))

            # The tree hash the index would have recorded: the registry root's own hash,
            # without the wrapping `General-<commit>/` directory `materialize` strips off.
            stripped = joinpath(work, "stripped.tar.gz")
            tar_gz(old_top, stripped)
            expected_tree = open(io -> Tar.tree_hash(GzipDecompressorStream(io)), stripped)

            # The live registry at `LIVE_REF`: 1.1.0 has since been yanked.
            live_root = joinpath(work, "live")
            build_registry(live_root, commit; yanked_112 = true)
            tar_gz(live_root, joinpath(srcdir, RS.LIVE_REF))

            tarball_url = "file://$srcdir"

            dest = joinpath(work, "patched")
            RS.materialize(commit, expected_tree, tarball_url, dest; check_yanked = true)
            toml = TOML.parsefile(joinpath(dest, "General.toml"))
            archive = joinpath(dest, toml["path"]::String)

            df = read_versions(archive, "D/DataFrames/Versions.toml")
            @test df["1.1.0"]["yanked"] == true
            @test !haskey(df["1.0.0"], "yanked")

            # An unrelated file must come through byte-for-byte, not just "unyanked".
            example = read_versions(archive, "E/Example/Versions.toml")
            @test !haskey(example["0.1.0"], "yanked")
            @test example["0.1.0"]["git-tree-sha1"] == "d"^40

            # The recorded tree hash must reflect what was actually patched onto disk, not the
            # original (now stale) hash from the index.
            @test toml["git-tree-sha1"] != expected_tree

            # `check_yanked = false` must skip the live fetch entirely and leave the archive,
            # and its recorded tree hash, exactly as fetched.
            dest_unchecked = joinpath(work, "unchecked")
            RS.materialize(commit, expected_tree, tarball_url, dest_unchecked; check_yanked = false)
            toml_unchecked = TOML.parsefile(joinpath(dest_unchecked, "General.toml"))
            @test toml_unchecked["git-tree-sha1"] == expected_tree
        end
    end
end
