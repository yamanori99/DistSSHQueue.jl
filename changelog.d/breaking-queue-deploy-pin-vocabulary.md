category: breaking

- Lockstep with DistSSHRun deploy-pin rename (PR3): job `kwargs` key `snapshot`
  → `run_id`; queue-only pin keys `snapshot_hosts` / `snapshot_project` /
  `snapshot_remote` → `ship_hosts` / `ship_project` / `ship_deploy_root`.
  Forwarding to detached `execute!` and per-job `setup!` uses `run_id=`.
- Reloaded `jobs.toml` rows validate `run_id` with public
  `DistSSHRun.validate_run_id`. No read fallback for legacy `snapshot` keys
  (pins existed only on unreleased `main`).
- Docs and archive wording use `provenance.selection` instead of
  `provenance.shipped`.
