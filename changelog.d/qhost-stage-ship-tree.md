category: breaking

- Client `qhost:` submit stages with DistSSHRun `pack_ship_tree` and `pack_shipment`
  (verified tar over SSH) instead of client-side rsync. The staged file set
  matches Kit `setup!(:ship_tree)`, not rsync/git-list alone. The queue host
  needs a remote Julia for extract. Out-of-tree scripts still land under
  `_distsshrun_external/` on the stage dir. A failed ship does not enqueue
  (no ticket / no row). Jobs record the staged `content_tree_hash` at submit;
  pack warnings (for example a gitignored `Manifest.toml` or `Manifest-v*.toml`)
  are stored on the job and printed after submit. Fetch still uses rsync.
