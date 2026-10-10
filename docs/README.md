# Docs

Documenter site for DistSSHQueue.jl. Sources live in `docs/src/`.

The site is Home and API. The longer guide is the
[DistSSHKit manual](https://yamanori99.github.io/DistSSHKit.jl/stable/).

```bash
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs docs/make.jl
```

Output: `docs/build/`. Use `--project=docs` (not the package root).

Logos and social preview: see [`src/assets/README.md`](src/assets/README.md).
Regenerate with `julia --project=docs/src/assets/logo docs/src/assets/logo/draw.jl`
(pinned Luxor; add `--png` for rasters).
