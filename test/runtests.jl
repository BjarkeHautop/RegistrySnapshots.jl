using RegistrySnapshots
using Dates
using Test

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
end
