module AirspeedVelocity

module Utils

export benchmark

using Pkg: PackageSpec
using Pkg: Pkg
using JSON3: JSON3
using FilePathsBase: isabspath, absolute, PosixPath

function _get_script(package_name)
    # Create temp env, add package, and get path to benchmark script.
    @info "Downloading package's latest benchmark script, assuming it is in benchmark/benchmarks.jl"
    tmp_env = mktempdir()
    to_exec = quote
        using Pkg
        Pkg.add(PackageSpec(; name=$package_name); io=devnull)
        using $(Symbol(package_name)): $(Symbol(package_name))
        root_dir = dirname(dirname(pathof($(Symbol(package_name)))))
        open(joinpath($tmp_env, "package_path.txt"), "w") do io
            write(io, root_dir)
        end
    end
    path_getter = joinpath(tmp_env, "path_getter.jl")
    open(path_getter, "w") do io
        println(io, to_exec)
    end
    run(`julia --project="$tmp_env" "$path_getter"`)

    script = joinpath(
        readchomp(joinpath(tmp_env, "package_path.txt")), "benchmark", "benchmarks.jl"
    )
    if !isfile(script)
        @error "Could not find benchmark script at $script. Please specify the `script` manually."
    end
    @info "Found benchmark script at $script."

    return script
end

function _benchmark(
    spec::PackageSpec;
    output_dir::String,
    script::String,
    tune::Bool,
    exeflags::Cmd,
)
    cur_dir = pwd()
    # Make sure paths are absolute, otherwise weird
    # behavior inside process:
    if !isabspath(output_dir)
        output_dir = string(absolute(PosixPath(output_dir)))
    end
    if !isabspath(script)
        script = string(absolute(PosixPath(script)))
    end
    package_name = spec.name
    package_rev = spec.rev
    spec_str = string(package_name) * "@" * string(package_rev)
    old_project = Pkg.project().path
    tmp_env = mktempdir()
    @info "    Creating temporary environment."
    Pkg.activate(tmp_env; io=devnull)
    @info "    Adding packages."
    Pkg.add(
        [spec, PackageSpec(; name="BenchmarkTools"), PackageSpec(; name="JSON3")];
        io=devnull,
    )
    Pkg.activate(old_project; io=devnull)
    results_filename = joinpath(output_dir, "results_" * spec_str * ".json")
    to_exec = quote
        using BenchmarkTools: run, BenchmarkGroup
        using JSON3: JSON3

        cd($cur_dir)
        # Include benchmark, defining SUITE:
        @info "    [runner] Including benchmark script: " * $script * "."
        include($script)
        # Assert that SUITE is defined:
        if !isdefined(Main, :SUITE)
            @error "    [runner] Benchmark script " * $script * " did not define SUITE."
        end
        if !(typeof(SUITE) <: BenchmarkGroup)
            @error "    [runner] Benchmark script " * $script * " did not define SUITE as a BenchmarkGroup."
        end
        if $tune
            @info "    [runner] Tuning benchmarks."
            tune!(SUITE)
        end
        @info "    [runner] Running benchmarks for " * $spec_str * "."
        @info "-"^80
        results = run(SUITE; verbose=true)
        @info "-"^80
        @info "    [runner] Finished benchmarks for " * $spec_str * "."
        open($results_filename, "w") do io
            JSON3.write(io, results)
        end
        @info "    [runner] Benchmark results saved at " * $results_filename
    end
    runner_filename = joinpath(tmp_env, "runner.jl")
    open(runner_filename, "w") do io
        println(io, string(to_exec))
    end
    @info "    Launching benchmark runner."
    run(`julia --project="$tmp_env" $exeflags "$runner_filename"`)
    # Return results from JSON file:
    @info "    Benchmark runner exited."
    @info "    Reading results."
    results = open(results_filename, "r") do io
        JSON3.read(io, Dict{String,Any})
    end
    @info "    Finished."
    return results
end

"""
    benchmark(package_name::String, rev::Union{String,Vector{String}}; output_dir::String=".", script::Union{String,Nothing}=nothing, tune::Bool=false, exeflags::Cmd=``)

Run benchmarks for a given Julia package.

This function runs the benchmarks specified in the `script` for the package defined by the `package_spec`. If `script` is not provided, the function will use the default benchmark script located at `{PACKAGE_SRC_DIR}/benchmark/benchmarks.jl`.

The benchmarks are run using the `SUITE` variable defined in the benchmark script, which should be of type BenchmarkTools.BenchmarkGroup. The benchmarks can be run with or without tuning depending on the value of the `tune` argument.

The results of the benchmarks are saved to a JSON file named `results_packagename@rev.json` in the specified `output_dir`.

# Arguments
- `package_name::String`: The name of the package for which to run the benchmarks.
- `rev::Union{String,Vector{String}}`: The revision of the package for which to run the benchmarks. You can also pass a vector of revisions to run benchmarks for multiple versions of a package.
- `output_dir::String="."`: The directory where the benchmark results JSON file will be saved (default: current directory).
- `script::Union{String,Nothing}=nothing`: The path to the benchmark script file. If not provided, the default script at `{PACKAGE}/benchmark/benchmarks.jl` will be used.
- `tune::Bool=false`: Whether to run benchmarks with tuning (default: false).
- `exeflags::Cmd=```: Additional execution flags for running the benchmark script (default: empty).
"""
function benchmark(
    package_name::String,
    revs::Vector{String};
    output_dir::String=".",
    script::Union{String,Nothing}=nothing,
    tune::Bool=false,
    exeflags::Cmd=``,
)
    return benchmark(
        [PackageSpec(; name=package_name, rev=rev) for rev in revs];
        output_dir=output_dir,
        script=script,
        tune=tune,
        exeflags=exeflags,
    )
end
function benchmark(
    package_name::String,
    rev::String;
    output_dir::String=".",
    script::Union{String,Nothing}=nothing,
    tune::Bool=false,
    exeflags::Cmd=``,
)
    return benchmark(
        package_name,
        [rev];
        output_dir=output_dir,
        script=script,
        tune=tune,
        exeflags=exeflags,
    )
end

"""
    benchmark(package::Union{PackageSpec,Vector{PackageSpec}}; output_dir::String=".", script::Union{String,Nothing}=nothing, tune::Bool=false, exeflags::Cmd=``)

Run benchmarks for a given Julia package.

This function runs the benchmarks specified in the `script` for the package defined by the `package_spec`. If `script` is not provided, the function will use the default benchmark script located at `{PACKAGE_SRC_DIR}/benchmark/benchmarks.jl`.

The benchmarks are run using the `SUITE` variable defined in the benchmark script, which should be of type BenchmarkTools.BenchmarkGroup. The benchmarks can be run with or without tuning depending on the value of the `tune` argument.

The results of the benchmarks are saved to a JSON file named `results_packagename@rev.json` in the specified `output_dir`.

# Arguments
- `package::Union{PackageSpec,Vector{PackageSpec}}`: The package specification containing information about the package for which to run the benchmarks. You can also pass a vector of package specifications to run benchmarks for multiple versions of a package.
- `output_dir::String="."`: The directory where the benchmark results JSON file will be saved (default: current directory).
- `script::Union{String,Nothing}=nothing`: The path to the benchmark script file. If not provided, the default script at `{PACKAGE}/benchmark/benchmarks.jl` will be used.
- `tune::Bool=false`: Whether to run benchmarks with tuning (default: false).
- `exeflags::Cmd=```: Additional execution flags for running the benchmark script (default: empty).
"""
function benchmark(
    package_spec::PackageSpec;
    output_dir::String=".",
    script::Union{String,Nothing}=nothing,
    tune::Bool=false,
    exeflags::Cmd=``,
)
    if script === nothing
        script = _get_script(package_name)
    end
    @info "Running benchmarks for " * package_spec.name * "@" * package_spec.rev * ":"
    return _benchmark(package_spec; output_dir, script, tune, exeflags)
end
function benchmark(
    package_specs::Vector{PackageSpec};
    output_dir::String=".",
    script::Union{String,Nothing}=nothing,
    tune::Bool=false,
    exeflags::Cmd=``,
)
    if script === nothing
        package_name = first(package_specs).name
        if !all(p -> p.name == package_name, package_specs)
            @error "All package specifications must have the same package name if you do not specify a `script`."
        end

        script = _get_script(package_name)
    end
    results = Dict{String,Any}()
    for spec in package_specs
        results[spec.name * "@" * spec.rev] = benchmark(
            spec; output_dir, script, tune, exeflags
        )
    end
    return results
end
end # module AirspeedVelocity.Utils

module BenchPkg

    using ..Utils: benchmark
    using Comonicon

    """
    Benchmark a package over a set of revisions.

    # Arguments

    - `package_name`: Name of the package.
    - `rev`: Revisions to test.

    # Options

    - `-o, --output_dir <arg>`: Where to save the JSON results.
    - `-s, --script <arg>`: The benchmark script. Default: `{PACKAGE_SRC_DIR}/benchmark/benchmarks.jl`.
    - `-e, --exeflags <arg>`: CLI flags for Julia (default: none).

    # Flags

    - `-t, --tune`: Whether to run benchmarks with tuning (default: false).

    """
    @main function benchpkg(
        package_name::String,
        rev::String...;
        output_dir::String=".",
        script::String="",
        exeflags::String="",
        tune::Bool=false,
    )
        benchmark(
            package_name,
            [rev...];
            output_dir=output_dir,
            script=(length(script) > 0 ? script : nothing),
            tune=tune,
            exeflags=(length(exeflags) > 0 ? `$exeflags` : ``),
        )

        return nothing
    end
end # module AirspeedVelocity.BenchPkg

using .Utils
export benchmark

end # module AirspeedVelocity
