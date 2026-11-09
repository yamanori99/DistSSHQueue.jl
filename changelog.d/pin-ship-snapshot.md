category: added

- Per-job `setup!(:ship_tree)` keeps DistSSHRun `result_remote_run_id` on that job (`snapshot`, with the child host set, project, and remote). The same id is passed as `snapshot=` to `:instantiate`, `:check`, and detached `execute!`. A later ship on another job does not retarget this one. A successful ship without that id is an error; there is no fallback to latest. Requires DistSSHRun's snapshot-id API (merged #357 on `main`).
