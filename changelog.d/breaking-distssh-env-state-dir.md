category: breaking

- **`DISTSSH_*` environment variables** replace the former `DISTSSHKIT_*` names (`DISTSSH_TEST`, `DISTSSH_TEST_SSH`, `DISTSSH_QUIET`, `DISTSSH_PROGRESS`, `DISTSSH_VERBOSE`, `DISTSSH_YES`, and other `DISTSSH_TEST_*` hooks). Queue does not read the old names; update config `[env]` and process env.
- **Local state directory** for new run artifacts is `.distssh/` (DistSSHRun `LOCAL_STATE_DIR`). Queue still recognizes legacy `.distsshkit/` trees for fetch, path checks, and rsync excludes, but new hidden fetch paths and setup-log recording prefer `.distssh/`.
