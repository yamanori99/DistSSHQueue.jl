---
category: breaking
---

Config `hosts` must use Run 0.2 machine tokens (`4*host1`, bare `host2`); `parent` / `child:` and submit `--workers` are rejected with migration hints. Head placement uses `--head-workers` / `--head-slots`, not registry rows. Existing configs need a manual `hosts` rewrite before load succeeds.