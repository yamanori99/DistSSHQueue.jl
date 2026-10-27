category: planned

- `status` will not show a `:running` row whose `kit.pid` is dead as running.
  The stored row stays `:running` until `serve` writes it.
