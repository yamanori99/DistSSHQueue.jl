category: added

- A finished or cancelled job keeps a byte copy of the controller `run.toml` under the queue data directory (`run-toml/<job-id>/run.toml`) and stores that file's SHA-256 on the job. `content_tree_hash` and `remote_run_id` are stored when that file has `provenance.shipped`. Jobs that share a `submission` and differ in `content_tree_hash` record one warning.
