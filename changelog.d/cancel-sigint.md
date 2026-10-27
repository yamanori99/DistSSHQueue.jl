category: planned

- `cancel` of a `:running` job will send SIGINT before SIGTERM, once
  DistSSHRun's `interrupt_grace` defaults to a positive value. Until then
  `cancel` does not send SIGINT.
