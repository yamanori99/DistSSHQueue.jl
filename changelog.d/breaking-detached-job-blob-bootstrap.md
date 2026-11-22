category: breaking

- Lockstep with DistSSHRun detached job blob bootstrap (PR 571 on `main`). `serve` still launches via `execute!(...; detached=true)`; child argv after `go` / `drive` is bootstrap only (`-y` / `--yes` and `--job-blob PATH`). Queue rejects `env=` and `env_allow=` on job kwargs so placement and run options are not re-injected into the child environment. `DISTSSH_JOB_BLOB` is not set on detached children (argv only).
