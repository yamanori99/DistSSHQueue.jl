category: breaking

- `submit ride` and DistSSHKit execute kind `:ride` are removed (lockstep with Run 0.2). Use `submit go` or `submit drive`. Queued or persisted `ride` rows in `jobs.toml` fail at load with a migration hint; `store_format_version` / `job_format_version` are unchanged because the row shape is the same.