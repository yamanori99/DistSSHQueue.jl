# Docs

Documenter site for DistSSHQueue.jl. Sources live in `docs/src/`.

Layout (same headings as DistSSHKit; Queue verbs only — do not copy Kit
`go` / `ride` / `drive` / `setup` pages):

- **Introduction** — `index.md`
- **First Steps** — `requirements.md`, `tutorial/`
  (`prepare.md`, `client.md`, `walkthrough.md`)
- **User Guide** — `manual/`
- **API** — `api.md`

Placement tokens and Kit flags stay in the
[kit docs](https://yamanori99.github.io/DistSSHKit.jl/stable/).

```bash
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs docs/make.jl
```

Output: `docs/build/`. Use `--project=docs` (not the package root).

Logos and social preview: see [`src/assets/README.md`](src/assets/README.md).
Regenerate with `julia --project=docs/src/assets/logo docs/src/assets/logo/draw.jl`
(pinned Luxor; add `--png` for rasters).
