struct TrajectoryBuffer{B1<:ElasticBuffer,B2<:ElasticBuffer}
    trajectory::B1
    terminal::B2
end

function TrajectoryBuffer(env::AbstractEnvironment; sizehint::Union{Integer,Nothing} = nothing, dtype::Maybe{DataType} = nothing)
    sp = dtype === nothing ? spaces(env) : adapt(dtype, spaces(env))

    trajectory = ElasticBuffer(
        states = sp.statespace,
        observations = sp.obsspace,
        actions = sp.actionspace,
        rewards = sp.rewardspace,
        evaluations = sp.evalspace
    )

    terminal = ElasticBuffer(
        states = sp.statespace,
        observations = sp.obsspace,
        dones = Bool,
        lengths = Int,
    )

    if !isnothing(sizehint)
        sizehint!(trajectory, sizehint)
        sizehint!(terminal, sizehint)
    end

    TrajectoryBuffer(trajectory, terminal)
end


struct EnvSampler{E<:AbstractEnvironment,B<:TrajectoryBuffer,BA}
    envs::Vector{E}
    bufs::Vector{B}
    batch::BA
end

function EnvSampler(env_tconstructor::Function; sizehint::Union{Integer,Nothing} = nothing, dtype::Maybe{DataType} = nothing)
    envs = [e for e in env_tconstructor(Threads.nthreads())]
    bufs = [TrajectoryBuffer(first(envs), sizehint=sizehint, dtype=dtype) for _ = 1:Threads.nthreads()]
    batch = makebatch(first(envs), sizehint=sizehint, dtype=dtype)
    EnvSampler(envs, bufs, batch)
end

function emptybufs!(sampler::EnvSampler)
    for buf in sampler.bufs
        empty!(buf.trajectory)
        empty!(buf.terminal)
    end
end


function sample!(
    actionfn!,
    resetfn!,
    sampler::EnvSampler,
    nsamples::Integer;
    Hmax::Integer = nsamples,
    nthreads::Integer = Threads.nthreads(),
    copy::Bool = false,
)
    nsamples > 0 || error("nsamples must be > 0")
    (0 < Hmax <= nsamples) || error("Hmax must be 0 < Hmax <= nsamples")
    (
        0 < nthreads <= Threads.nthreads()
    ) || error("nthreads must b 0 < nthreads < Threads.nthreads()")

    atomiccount = Threads.Atomic{Int}(0)
    atomicidx = Threads.Atomic{Int}(1)

    nthreads = _defaultnthreads(nsamples, Hmax, nthreads)
    emptybufs!(sampler)

    if nthreads == 1
        _threadsample!(actionfn!, resetfn!, sampler, nsamples, Hmax)
    else
        @sync for _ = 1:nthreads
            Threads.@spawn _threadsample!(
                actionfn!,
                resetfn!,
                sampler,
                nsamples,
                Hmax,
                atomiccount,
            )
        end
    end

    @assert sum(b -> length(b.trajectory), sampler.bufs) >= nsamples

    collate!(sampler, nsamples, copy)
    sampler.batch
end

function _threadsample!(actionfn!::F, resetfn!::G, sampler, nsamples, Hmax) where {F,G}
    env = sampler.envs[Threads.threadid()]
    buf = sampler.bufs[Threads.threadid()]
    traj = buf.trajectory
    term = buf.terminal

    resetfn!(env)
    trajlength = n = 0
    while n < nsamples
        done = rolloutstep!(actionfn!, traj, env)
        trajlength += 1

        if done || trajlength == Hmax
            terminate!(term, env, trajlength, done)
            resetfn!(env)
            n += trajlength
            trajlength = 0
        end
    end
    sampler
end




function _threadsample!(
    actionfn!::F,
    resetfn!::G,
    sampler,
    nsamples,
    Hmax,
    atomiccount,
) where {F,G}
    env = sampler.envs[Threads.threadid()]
    buf = sampler.bufs[Threads.threadid()]
    traj = buf.trajectory
    term = buf.terminal

    resetfn!(env)
    trajlength = 0
    while true
        done = rolloutstep!(actionfn!, traj, env)
        trajlength += 1

        if atomiccount[] >= nsamples
            break
        elseif atomiccount[] + trajlength >= nsamples
            Threads.atomic_add!(atomiccount, trajlength)
            terminate!(term, env, trajlength, done)
            break
        elseif done || trajlength == Hmax
            Threads.atomic_add!(atomiccount, trajlength)
            terminate!(term, env, trajlength, done)
            resetfn!(env)
            trajlength = 0
        end
    end
    sampler
end


function rolloutstep!(actionfn!::F, traj::ElasticBuffer, env::AbstractEnvironment) where {F}
    grow!(traj)
    t = lastindex(traj)
    @uviews traj begin
        st, ot, at =
            view(traj.states, :, t), view(traj.observations, :, t), view(traj.actions, :, t)

        getstate!(st, env)
        getobs!(ot, env)
        actionfn!(at, st, ot)

        setaction!(env, at)
        step!(env)

        r = getreward(st, at, ot, env)
        e = geteval(st, at, ot, env)
        done = isdone(st, at, ot, env)

        traj.rewards[t] = r
        traj.evaluations[t] = e
        return done
    end
end

function terminate!(term::ElasticBuffer, env::AbstractEnvironment, trajlength::Integer, done::Bool)
    grow!(term)
    i = lastindex(term)
    @uviews term begin
        thistraj = view(term, i)
        getstate!(vec(thistraj.states), env) # TODO
        getobs!(vec(thistraj.observations), env) # TODO
        term.dones[i] = done
        term.lengths[i] = trajlength
    end
    term
end


function makebatch(env::AbstractEnvironment; sizehint::Union{Integer,Nothing} = nothing, dtype::Maybe{DataType} = nothing)
    sp = dtype === nothing ? spaces(env) : adapt(dtype, spaces(env))
    batch = (
        states = BatchedArray(sp.statespace),
        observations = BatchedArray(sp.obsspace),
        actions = BatchedArray(sp.actionspace),
        rewards = BatchedArray(sp.rewardspace),
        evaluations = BatchedArray(sp.evalspace),
        terminal_states = BatchedArray(sp.statespace),
        terminal_observations = BatchedArray(sp.obsspace),
        dones = Vector{Bool}(),
    )
    !isnothing(sizehint) && foreach(el -> sizehint!(el, sizehint), batch)
    batch
end

function collate!(sampler::EnvSampler, n::Integer, copy::Bool)
    batch = copy ? map(deepcopy, sampler.batch) : sampler.batch
    for b in batch
        empty!(b)
        sizehint!(b, n)
    end

    count = 0
    maxlen = maximum(map(buf -> length(buf.terminal), sampler.bufs))
    for i = 1:maxlen, (tid, buf) in enumerate(sampler.bufs)
        count >= n && break

        trajbuf = buf.trajectory
        termbuf = buf.terminal
        length(termbuf) < i && continue

        @uviews trajbuf termbuf begin
            from = i == 1 ? 1 : sum(view(termbuf.lengths, 1:i-1)) + 1
            len = termbuf.lengths[i]
            len = count + len > n ? n - count : len
            to = from + len - 1

            traj = view(trajbuf, from:to)
            term = view(termbuf, i)

            push!(batch.states, traj.states)
            push!(batch.observations, traj.observations)
            push!(batch.actions, traj.actions)
            push!(batch.rewards, traj.rewards)
            push!(batch.evaluations, traj.evaluations)
            push!(batch.terminal_states, reshape(term.states, (:, 1)))
            push!(batch.terminal_observations, reshape(term.observations, (:, 1)))
            push!(batch.dones, termbuf.dones[i])

            count += length(from:to)
            from = to + 1
        end
    end

    nbatches = length(batch.dones)
    @assert length(batch.terminal_states) ==
            length(batch.terminal_observations) ==
            length(batch.dones)
    @assert nsamples(batch.states) == n
    @assert nsamples(batch.observations) == n
    @assert nsamples(batch.actions) == n
    @assert nsamples(batch.rewards) == n
    @assert nsamples(batch.evaluations) == n


    batch
end


function _defaultnthreads(nsamples, Hmax, nthreads)
    d, r = divrem(nsamples, Hmax)
    if r > 0
        d += 1
    end
    min(d, nthreads)
end