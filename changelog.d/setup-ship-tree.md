category: breaking

- Per-job setup calls DistSSHRun `setup!(session, :ship_tree)`. `:rsync` is not passed. `gitignore=false` is not passed, including for a qhost stage directory. While that step runs, `status` shows `ship-tree`.
