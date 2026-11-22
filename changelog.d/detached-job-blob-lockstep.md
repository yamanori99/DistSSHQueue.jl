category: added

- Lockstep with DistSSHRun detached job-blob bootstrap (merged #571 on `main`): `serve` still calls `execute!(…; detached=true)` only with kwargs Run accepts for the blob. Tests assert Kit children boot with `-y` and `--job-blob PATH` only and without `DISTSSH_JOB_BLOB` in the child environment. Queue user-facing CLI and `submit!` are unchanged.
