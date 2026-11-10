category: breaking

- `teardown` no longer treats `-y`, `--yes`, or `DISTSSH_YES` (process or config `[env]`) as permission to delete. Without a matching `--confirm-path`, that attempt exits 1 and deletes nothing. With no attempt, `teardown` prints `Would remove` and exits 0. `up default` still honors `DISTSSH_YES`.
- A default config `[env]` applied before `--config` does not choose the store or the config of the home being removed. A `DISTSSHQUEUE_STORE` or `DISTSSHQUEUE_CONFIG` already in the process still does.
- `teardown` exits 1 and deletes nothing while a `:running` job has a live `kit.pid`. It does not stop `serve`. `--stop-jobs` calls `terminate_run!` only together with a matching `--confirm-path`, then deletes. A `:running` row with no live `kit.pid` does not block. `--stop-jobs` with `--write-only` exits 1 and signals nothing.
