category: fixed

- `cancel` of a running job does not record the `.distsshkit/runs/` directory as `result_path`. DistSSHRun `terminate_run!` writes that directory as `output_dir` when `kit.result` is missing. The recorded path stays the `run.toml` `output_dir`, or unset when that key is absent.
