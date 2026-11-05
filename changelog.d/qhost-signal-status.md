category: breaking

- A `qhost:` hop whose local `ssh` is killed by a signal exits
  `128 + signal` (SIGINT 130, SIGPIPE 141, SIGKILL 137, SIGTERM 143).
  That hop used to exit 0, so `status`, `submit`, `cancel`, `stop`,
  and `teardown` looked successful. `submit` writes no client ticket.
  A hop that prints and then dies no longer counts as success for
  staging or `fetch`. Exits 0, 3, and 255 are unchanged.
