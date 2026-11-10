category: breaking

- `cancel` of a `:running` job with a live `kit.pid` sends SIGINT once,
  then SIGTERM. The wait is 30 seconds, or `DISTSSH_WAIT_SIGINT_GRACE`
  in the process that calls `cancel`. The driver host does not read that
  variable. `0` sends no SIGINT.
