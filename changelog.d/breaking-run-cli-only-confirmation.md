category: breaking

- `submit!` no longer accepts `yes=` (confirmation is CLI-only on DistSSHRun 0.2). Programmatic enqueue and serve must not pass it; unattended detached children rely on Run's job blob.
- Per-job deploy checks use `doctor!(; deploy=true)` instead of removed `setup!(:check)` (Run 0.2).
