category: breaking

- Job and remote project env names match DistSSHRun 0.2.0: `DISTSSH_PROJECT_ROOT`,
  `DISTSSH_REMOTE_PROJECT_ROOT`, and `DISTSSH_SSH_OPTS`. A leftover
  `DISTRIBUTED_*` name is an error that prints the replacement. `qhost:` stage
  sets `DISTSSH_PROJECT_ROOT` for the child. `JULIA_DISTRIBUTED_EXE` is unchanged.
