category: breaking

- `submit!` no longer accepts `yes=` (confirmation is CLI-only on DistSSHRun 0.2). Programmatic enqueue and serve must not pass it; unattended detached children rely on Run's job blob.
- Per-job `setup!(:check)` no longer passes `run_id=` (Run 0.2 allows `run_id` only on `:instantiate` / `:runtest`).
