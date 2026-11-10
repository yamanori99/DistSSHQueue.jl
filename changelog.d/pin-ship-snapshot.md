category: added

- Per-job `setup!(:ship_tree)` keeps DistSSHRun `result_remote_run_id` on that job (`run_id`, with the child host set, project, and remote). The same id is passed as `run_id=` to `:instantiate`, `:check`, and detached `execute!`. A later ship on another job does not retarget this one. A successful ship without that id is an error; there is no fallback to latest. Requires DistSSHRun's run-id API (merged #357 on `main`; vocabulary PR3 in #402).
