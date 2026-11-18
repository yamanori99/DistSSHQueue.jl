category: breaking

- `submit!` no longer accepts `yes=` (confirmation is CLI-only on DistSSHRun 0.2). Programmatic enqueue and serve must not pass it; unattended detached children rely on Run's job blob.
- Per-job deploy checks use `doctor!(; deploy=true)` instead of removed `setup!(:check)` (Run 0.2).
- Serve runs local `Pkg.instantiate` before `setup!(:ship_tree)` so the controller shipped-tree gate stays current (Run 0.2).
- Kit setup re-checks enqueue tree hash without `assert_controller_shipped_tree_current!`, so a long-lived `serve` is not blocked by another job's in-process ship record.
