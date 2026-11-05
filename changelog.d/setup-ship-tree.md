category: breaking

- Per-job setup calls DistSSHRun `setup!(session, :ship_tree)`. `:rsync` is not passed. `gitignore=false` is not passed, including for a qhost stage directory. While that step runs, `status` shows `ship-tree`.
- When the job remote is an absolute path, per-job setup calls `setup!(session, :remote_root)` before `:ship_tree`. Run creates that directory when it is missing. A missing or relative remote does not call `:remote_root`. While that step runs, `status` shows `remote-root`.
