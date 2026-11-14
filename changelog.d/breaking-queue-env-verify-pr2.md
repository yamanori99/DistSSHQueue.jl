category: breaking

- `submit!` and `serve` call DistSSHRun `assert_controller_environment_for_verify!`
  on the job project before enqueue and before Kit setup: the Manifest digest gate,
  `Pkg.is_manifest_current` must be `true`, and the controller must use the default
  Julia sysimage (`--unsafe-heterogeneous` still waives only Manifest/Project
  digests on workers, not these controller gates).
- `jobs.toml` carries `store_format_version` and each job row carries
  `job_format_version`. Queue 0.9 rows without `job_format_version` are refused;
  mismatched client and serve binaries sharing one store are refused with
  what/where/why/fix text (drain the queue and upgrade both).
- At submit, Queue resolves the Kit project with DistSSHRun/Base
  `resolve_pkg_project_dir` and records `enqueue_project` and
  `enqueue_content_tree_hash` (`DistSSHRun.pack_ship_tree`). At execution the
  tree is re-hashed and the job fails closed when it changed.
- Job setup identity checks follow DistSSHRun worker verification, including
  resolved `sysimage=` paths (tests use `DISTSSH_TEST_RUN_IDENTITY_SYSIMAGE`).