category: breaking

- Queue-host instantiate of a job tree fails when the active Manifest `julia_version` is missing, is not a Julia version, or its minor differs from the Julia running `serve`. The error names `help setup`. A matching minor instantiates with `manifest=true`, `update_registry=false`, and `julia_version_strict=true`. A tree with no Manifest still uses plain `Pkg.instantiate()`.
