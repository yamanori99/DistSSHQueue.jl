category: planned

- `-y`, `--yes`, and `DISTSSHKIT_YES` will stop authorizing `teardown`.
  Without `--confirm-path`, `-y` will exit 1. A `teardown` that was not
  asked to delete still prints `Would remove` and exits 0. `up default`
  still honors `DISTSSHKIT_YES`.
