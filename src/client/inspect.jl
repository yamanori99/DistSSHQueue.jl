# Shared stdout for inspect verbs (`pool`) on the queue host.

function print_pool_inventory_notes!(; io::IO = stdout)
    println(io, "Note: the head machine is always listed first; registry rows are remote SSH hosts.")
    return nothing
end
