# Shared stdout for inspect verbs (`pool`) on the queue host.

function print_pool_inventory_notes!(; io::IO = stdout)
    println(io, "Note: parent is this queue host (Kit token, not an SSH Host alias).")
    return nothing
end
