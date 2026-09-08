"""Shared stdout for inspect verbs (`size` / `plan` / `pool`) on the queue host."""

const INSPECT_SUBMIT_HEADER = "Suggested submit (template):"

function print_inspect_submit_template(kind::AbstractString, parts::Vector{String})
    println(INSPECT_SUBMIT_HEADER)
    if isempty(parts)
        println("  julia --project=. -m DistSSHQueue submit $kind SCRIPT.jl")
    else
        println("  julia --project=. -m DistSSHQueue submit $kind ", join(parts, " "), " SCRIPT.jl")
    end
    return nothing
end

function pool_sizing_assumption_line(;
    gb_per_worker::Union{Nothing, Real},
    mem_headroom::Real,
    parent_gb::Real,
)::String
    pw = Float64(something(gb_per_worker, DistSSHKit.WORKER_MEMORY_GB_FALLBACK))
    return string(
        "Note: estimated workers from ",
        pw,
        " GB/worker, mem-headroom ",
        mem_headroom,
        ", parent-gb ",
        parent_gb,
        " (no RSS; use size to measure).",
    )
end

function print_pool_inventory_notes!(;
    gb_per_worker::Union{Nothing, Real},
    mem_headroom::Real,
    parent_gb::Real,
    io::IO=stdout,
)
    println(io, pool_sizing_assumption_line(;
        gb_per_worker=gb_per_worker,
        mem_headroom=mem_headroom,
        parent_gb=parent_gb,
    ))
    println(io, "Note: parent is this queue host (Kit token, not an SSH Host alias).")
    println(io, "Note: Kit slot counts are worker hints, not free queue capacity.")
    return nothing
end
