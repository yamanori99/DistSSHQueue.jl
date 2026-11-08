category: breaking

- Drop Queue `size` / `plan`. Worker-count heuristics, RSS, GB-per-worker
  templates, and suggested-submit footers are gone. `pool` prints cores,
  RAM, and reachability only (missing facts stay `-`, not `0`). Submit
  still takes explicit `parent:N` / `child:NAME:N` and `pool:N` (clamped
  by add-host max). DistSSHRun tracks
  `breaking/drop-size-add-hostinfo-c3b5` until that lands on main.
