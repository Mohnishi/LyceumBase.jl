module Tools

# stdlib
using LibGit2, Pkg, Statistics, Random, LinearAlgebra, InteractiveUtils, Logging, Dates
using Future: randjump

# 3rd party
import UnicodePlots
#using UnsafeArrays, StaticArrays, StatsBase, EllipsisNotation, ElasticArrays, MacroTools, JLSO, Parameters
using UnsafeArrays, StaticArrays, EllipsisNotation, ElasticArrays, MacroTools, JLSO, Parameters, Adapt

# Lyceum
import UniversalLogger: finish!
using ..LyceumBase, Shapes, UniversalLogger
using ..LyceumBase: TupleN, Maybe

include("misc.jl")
export
    delta,
    scaleandcenter!,
    zerofn,
    noop,
    symmul!,
    @forwardfield,
    wraptopi,
    tuplecat,
    Converged,
    noalloc,
    mkgoodpath,
    filter_nt,
    KahanSum

include("projectmeta.jl")

include("plotting.jl")
export Line, expplot

include("experiment.jl")
export Experiment, finish!

include("threading.jl")
export seed_threadrngs!, threadrngs, getrange, splitrange, nblasthreads, @with_blasthreads

include("meta.jl")

include("elasticbuffer.jl")
export ElasticBuffer, fieldarrays, grow!

include("batchedarray.jl")
export BatchedArray, flatview, batchlike

include("envsampler.jl")
export EnvSampler, sample!, TrajectoryBuffer, grow!

end # module