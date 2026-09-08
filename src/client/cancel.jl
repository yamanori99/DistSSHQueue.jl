"""Client `cancel <id>`. `:queued`, or `:running` when the Kit output dir is known (allocated at start if omitted)."""

function cancel_cli(args::Vector{String})::Cint
    isempty(args) && throw(ArgumentError("cancel: need a job id"))
    args[1] in ("-h", "--help") && (show_usage(); return 0)
    length(args) == 1 || throw(ArgumentError("cancel: extra arguments"))
    id = String(args[1])
    length(id) < 8 && throw(ArgumentError(
        "cancel: job id needs 8 characters (status prefix) or the full UUID",
    ))
    q = Queue(; store=store_path())
    cancelled = try
        cancel!(q, id)
    catch e
        e isa ArgumentError || rethrow()
        startswith(e.msg, "ambiguous") && rethrow()
        false
    end
    if cancelled
        println(id)
        return 0
    end
    DistSSHKit.print_cli_error("job $(repr(id)) cannot be cancelled")
    return 1
end
