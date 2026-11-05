#!/usr/bin/env julia
# Name-only check: DistSSHKit `src/` may not gain a new non-public
# DistSSHQueue reference. Queue is upstream of Kit, so this is Run's
# downstream scan pointed the other way (Kit calls Queue). What Queue
# calls on Run stays Run's Downstream job. `test/` is not scanned.
# Run from the Downstream job:
#   julia --startup-file=no --project=. .github/downstream_public.jl SRC_DIR

import Pkg

if abspath(PROGRAM_FILE) == @__FILE__
    Pkg.instantiate()
end

using DistSSHQueue

# Kit `src` on main already calls these. Neither is `public`.
# 310 added `julia -m DistSSHQueue` (`main`). 381 shared `leading_hop_span`
# with Kit and left it not `public`.
const DOWNSTREAM_PUBLIC_ALLOW = Dict{Tuple{Symbol, Symbol}, Int}(
    (:DistSSHQueue, :leading_hop_span) => 381,
    (:DistSSHQueue, :main) => 310,
)

function _binding_is_public(name::Symbol)::Bool
    return isdefined(DistSSHQueue, name) && Base.ispublic(DistSSHQueue, name)
end

# Outermost name last. A one-argument `.` is a bare name, not a chain.
function _chain_names(ex)::Union{Nothing, Vector{Symbol}}
    names = Symbol[]
    node = ex
    while node isa Expr && node.head === :. && length(node.args) >= 2
        piece = node.args[2]
        if piece isa QuoteNode && piece.value isa Symbol
            push!(names, piece.value::Symbol)
        elseif piece isa Symbol
            push!(names, piece)
        else
            return nothing
        end
        node = node.args[1]
    end
    if node isa Symbol
        push!(names, node)
    elseif node isa Expr && node.head === :. && length(node.args) == 1 && node.args[1] isa Symbol
        push!(names, node.args[1]::Symbol)
    else
        return nothing
    end
    return reverse!(names)
end

# First name is DistSSHQueue. A further name is a field, not another binding.
function _queue_name(chain::Vector{Symbol})::Union{Nothing, Symbol}
    if length(chain) < 2 || chain[1] !== :DistSSHQueue
        return nothing
    end
    return chain[2]
end

function _import_name(ex)::Union{Nothing, Symbol}
    if ex isa Symbol
        return ex
    elseif ex isa Expr && ex.head === :. && length(ex.args) == 1 && ex.args[1] isa Symbol
        return ex.args[1]::Symbol
    elseif ex isa Expr && ex.head === :as && !isempty(ex.args)
        return _import_name(ex.args[1])
    else
        return nothing
    end
end

function _walk(ex, file::String, line::Base.RefValue{Int}, hits::Vector{Tuple{String, Int, Symbol}})
    if ex isa LineNumberNode
        line[] = ex.line
        return nothing
    end
    ex isa Expr || return nothing
    if ex.head === :. && length(ex.args) >= 2
        chain = _chain_names(ex)
        if chain !== nothing
            name = _queue_name(chain)
            if name !== nothing
                push!(hits, (file, line[], name))
            end
        end
        return nothing
    elseif ex.head === :using || ex.head === :import
        for arg in ex.args
            _walk_import(arg, file, line[], hits)
        end
        return nothing
    end
    for arg in ex.args
        _walk(arg, file, line, hits)
    end
    return nothing
end

function _walk_import(arg, file::String, line::Int, hits::Vector{Tuple{String, Int, Symbol}})
    base = arg
    selected = Symbol[]
    if arg isa Expr && arg.head === :(:)
        base = arg.args[1]
        for name_ex in arg.args[2:end]
            name = _import_name(name_ex)
            name === nothing || push!(selected, name)
        end
    end
    if isempty(selected)
        # `import DistSSHQueue.name` (no colon list).
        chain = _chain_names(arg)
        chain === nothing && return nothing
        name = _queue_name(chain)
        name === nothing && return nothing
        push!(hits, (file, line, name))
        return nothing
    end
    chain = _chain_names(base)
    chain === nothing && return nothing
    # `using DistSSHQueue: name`. A submodule import is not a Queue binding.
    if length(chain) == 1 && chain[1] === :DistSSHQueue
        for name in selected
            push!(hits, (file, line, name))
        end
    end
    return nothing
end

function _body_binds_queue(ex)::Bool
    ex isa Expr || return false
    if ex.head === :call && !isempty(ex.args) && ex.args[1] === :_bind!
        for arg in ex.args[2:end]
            arg === :DistSSHQueue && return true
        end
    end
    for arg in ex.args
        _body_binds_queue(arg) && return true
    end
    return false
end

function _symbol_tuples!(ex, line::Base.RefValue{Int}, out::Dict{Symbol, Vector{Tuple{Symbol, Int}}})
    if ex isa LineNumberNode
        line[] = ex.line
        return nothing
    end
    ex isa Expr || return nothing
    if ex.head === :const && length(ex.args) == 1
        assign = ex.args[1]
        if assign isa Expr && assign.head === :(=) && length(assign.args) >= 2 &&
                assign.args[1] isa Symbol && assign.args[2] isa Expr &&
                assign.args[2].head === :tuple
            syms = Tuple{Symbol, Int}[]
            at = line[]
            for arg in assign.args[2].args
                if arg isa LineNumberNode
                    at = arg.line
                elseif arg isa QuoteNode && arg.value isa Symbol
                    push!(syms, (arg.value::Symbol, at))
                end
            end
            out[assign.args[1]::Symbol] = syms
        end
    end
    for arg in ex.args
        _symbol_tuples!(arg, line, out)
    end
    return nothing
end

function _bind_consts!(ex, found::Vector{Symbol})
    ex isa Expr || return nothing
    if ex.head === :for && length(ex.args) >= 2
        iter = ex.args[1]
        if iter isa Expr && iter.head === :(=) && length(iter.args) >= 2 &&
                iter.args[2] isa Symbol && _body_binds_queue(ex.args[2])
            push!(found, iter.args[2]::Symbol)
        end
    end
    for arg in ex.args
        _bind_consts!(arg, found)
    end
    return nothing
end

function _scan_file!(path::String, root::String, hits::Vector{Tuple{String, Int, Symbol}})
    ex = Meta.parseall(read(path, String); filename = path)
    rel = relpath(path, root)
    line = Ref(1)
    _walk(ex, rel, line, hits)
    tuples = Dict{Symbol, Vector{Tuple{Symbol, Int}}}()
    _symbol_tuples!(ex, Ref(1), tuples)
    consts = Symbol[]
    _bind_consts!(ex, consts)
    for const_name in consts
        for (name, at) in get(tuples, const_name, Tuple{Symbol, Int}[])
            push!(hits, (rel, at, name))
        end
    end
    return nothing
end

function _scan_tree(srcdir::AbstractString)::Vector{Tuple{String, Int, Symbol}}
    hits = Tuple{String, Int, Symbol}[]
    root = abspath(String(srcdir))
    for (dir, _, files) in walkdir(root)
        for file in files
            endswith(file, ".jl") || continue
            _scan_file!(joinpath(dir, file), root, hits)
        end
    end
    return hits
end

"""Failures for `srcdir` (Kit `src/`). Empty means the tree is allowed."""
function downstream_public_failures(
        srcdir::AbstractString;
        allow::Dict{Tuple{Symbol, Symbol}, Int} = DOWNSTREAM_PUBLIC_ALLOW,
    )::Vector{String}
    fails = String[]
    seen = Set{Tuple{String, Int, Symbol}}()
    for (file, line, name) in _scan_tree(srcdir)
        key = (file, line, name)
        key in seen && continue
        push!(seen, key)
        _binding_is_public(name) && continue
        haskey(allow, (:DistSSHQueue, name)) && continue
        push!(fails, "$(file):$(line): DistSSHQueue.$(name) is not public")
    end
    for ((owner, name), issue) in allow
        owner === :DistSSHQueue || continue
        _binding_is_public(name) || continue
        push!(fails, "allowlist: DistSSHQueue.$(name) is public; remove the #$(issue) entry")
    end
    return sort!(fails)
end

function downstream_public_main(args::Vector{String})::Cint
    if length(args) != 1
        println(stderr, "usage: downstream_public.jl SRC_DIR")
        return Cint(2)
    end
    src = args[1]
    if !isdir(src)
        println(stderr, "downstream_public: not a directory: $(src)")
        return Cint(2)
    end
    fails = downstream_public_failures(src)
    if isempty(fails)
        n = length(DOWNSTREAM_PUBLIC_ALLOW)
        println("downstream public names: ok ($(n) allowlisted)")
        return Cint(0)
    end
    for line in fails
        println(stderr, line)
    end
    return Cint(1)
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(downstream_public_main(ARGS))
end
