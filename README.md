# Compile bench

The charts are on [bench.html](https://yamanori99.github.io/DistSSHQueue.jl/bench.html).

Precompile time, load time, CLI wall time, `src/**/*.jl` size, and the host
(OS name, arch, CPU). `code lines` skips blank lines. A row is flagged when,
against the previous sample on the same Julia slot, the host OS or arch
changes, the Julia version changes, package precompile grows by 1.5x and 0.5s, a command wall grows
by 1.5x and 1s, or a method of at least 200 ms is new in the top 20 or
doubles. This does not fail CI. Each slot's table folds. The 1.13
table starts open.

## Flagged

- 1.13: status method new -> 570.0 ms: Tuple{DistSSHQueue.var"##show_status#223", Base.PipeEndpoint, Nothing, Bool, Nothing, Bool, typeof(D...
- 1.13: watch method new -> 648.0 ms: Tuple{DistSSHQueue.var"##watch!#227", Float64, Int64, Base.PipeEndpoint, Nothing, Bool, Nothing, Boo...
- 1.14-pre: status method new -> 512.8 ms: Tuple{DistSSHQueue.var"##show_status#223", Base.PipeEndpoint, Nothing, Bool, Nothing, Bool, typeof(D...
- 1.14-pre: watch method new -> 525.8 ms: Tuple{DistSSHQueue.var"##watch!#227", Float64, Int64, Base.PipeEndpoint, Nothing, Bool, Nothing, Boo...
- nightly: julia 1.15.0-DEV.632 -> 1.15.0-DEV.649
- nightly: status method new -> 496.0 ms: Tuple{DistSSHQueue.var"##show_status#223", Base.PipeEndpoint, Nothing, Bool, Nothing, Bool, typeof(D...
- nightly: watch method new -> 539.3 ms: Tuple{DistSSHQueue.var"##watch!#227", Float64, Int64, Base.PipeEndpoint, Nothing, Bool, Nothing, Boo...

<details open>
<summary>1.13</summary>

| date | commit | version | julia | os | arch | src files | code lines | full s | pkg s | using s | help s | status s | submit s | watch s | cancel s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-11-06 | cd30429 | 0.10.0-DEV | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7332 | 27.9 | 2.42 | 0.41 | 2.95 | 4.01 | 4.02 | 3.95 | 4.53 |
| 2026-11-06 | e8bf825 | 0.10.0-DEV | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7374 | 25.57 | 2.19 | 0.42 | 2.73 | 3.56 | 3.69 | 3.77 | 4.37 |
| 2026-11-06 | 47a9242 | 0.10.0-DEV | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7660 | 25.38 | 2.45 | 0.39 | 2.97 | 4.0 | 4.05 | 4.03 | 4.55 |
| 2026-11-06 | 6ef3b66 | 0.10.0-DEV | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 23 | 7608 | 25.82 | 2.45 | 0.4 | 3.02 | 4.03 | 4.09 | 4.07 | 4.64 |
| 2026-11-07 | 6ef3b66 | 0.10.0-DEV | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 23 | 7608 | 20.0 | 1.84 | 0.33 | 2.4 | 3.2 | 3.25 | 3.22 | 3.69 |
| 2026-11-08 | 647a29c | 0.10.0-DEV | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 23 | 7608 | 25.36 | 2.4 | 0.41 | 2.95 | 4.02 | 4.04 | 3.96 | 4.53 |
| 2026-11-08 | 0843a87 | 0.10.0-DEV | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 22 | 7492 | 20.41 | 1.88 | 0.35 | 2.49 | 3.32 | 3.37 | 3.25 | 3.83 |
| 2026-11-09 | 0843a87 | 0.10.0-DEV | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 22 | 7492 | 21.29 | 1.96 | 0.37 | 2.51 | 3.32 | 3.48 | 3.46 | 3.85 |
| 2026-11-09 | 82be25d | 0.10.0-DEV | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 22 | 7798 | 20.68 | 1.87 | 0.34 | 2.51 | 3.33 | 3.38 | 3.37 | 3.79 |
| 2026-11-10 | ce0e2a0 | 0.10.0-DEV | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 22 | 7798 | 21.72 | 1.82 | 0.35 | 2.3 | 3.1 | 3.16 | 3.14 | 3.66 |
| 2026-11-10 | 1740bae | 0.10.0-DEV | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 22 | 7820 | 27.34 | 2.21 | 0.41 | 3.0 | 4.1 | 4.14 | 4.04 | 4.66 |
| 2026-11-10 | 2e4bc63 | 0.10.0-DEV | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 22 | 7823 | 22.3 | 1.78 | 0.32 | 2.41 | 3.14 | 3.39 | 3.45 | 3.86 |

</details>

<details>
<summary>1.14-nightly</summary>

| date | commit | version | julia | os | arch | src files | code lines | full s | pkg s | using s | help s | status s | submit s | watch s | cancel s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-20 | 6d3a5c7 | 0.9.7 | 1.14.0-alpha1 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 7.79 | 2.03 | 0.35 | 0.78 | 2.01 | 2.22 | 1.96 | 2.06 |
| 2026-10-22 | 7c2c5df | 0.9.7 | 1.14.0-alpha1 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6735 | 6.2 | 1.67 | 0.28 | 0.62 | 1.6 | 1.83 | 1.59 | 1.71 |
| 2026-10-22 | ff6d630 | 0.9.7 | 1.14.0-alpha1 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6891 | 8.62 | 2.33 | 0.39 | 0.88 | 2.36 | 2.63 | 2.27 | 2.42 |
| 2026-10-22 | 6ae9bed | 0.9.7 | 1.14.0-alpha1 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6891 | 7.78 | 2.06 | 0.34 | 0.75 | 2.03 | 2.3 | 2.0 | 2.13 |
| 2026-10-23 | 33f99d4 | 0.9.8 | 1.14.0-alpha1 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7112 | 8.53 | 2.21 | 0.37 | 0.84 | 2.36 | 2.61 | 2.32 | 2.35 |
| 2026-10-24 | a7ddadc | 0.9.8 | 1.14.0-alpha1 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7168 | 8.37 | 2.2 | 0.36 | 0.81 | 2.18 | 2.57 | 2.2 | 2.28 |
| 2026-10-25 | f957764 | 0.9.9 | 1.14.0-alpha1.112 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7174 | 8.29 | 2.16 | 0.31 | 0.74 | 2.12 | 2.37 | 2.1 | 2.19 |
| 2026-10-26 | ebb72a5 | 0.9.10 | 1.14.0-alpha1.112 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7216 | 8.24 | 2.17 | 0.3 | 1.6 | 2.43 | 2.36 | 2.4 | 2.36 |
| 2026-10-26 | 045acf7 | 0.9.10 | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7241 | 8.47 | 2.21 | 0.31 | 1.63 | 2.03 | 1.88 | 2.03 | 2.12 |
| 2026-10-27 | 882e53f | 0.9.10 | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7300 | 6.4 | 1.71 | 0.25 | 1.36 | 1.6 | 1.47 | 1.58 | 1.64 |
| 2026-10-27 | 3bfc569 | 0.9.10 | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7300 | 4.85 | 1.32 | 0.2 | 1.1 | 1.26 | 1.16 | 1.22 | 1.27 |
| 2026-10-27 | 0669ccd | 0.9.11 | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7300 | 5.48 | 1.53 | 0.24 | 1.19 | 1.52 | 1.42 | 1.47 | 1.57 |

</details>

<details>
<summary>1.14-pre</summary>

| date | commit | version | julia | os | arch | src files | code lines | full s | pkg s | using s | help s | status s | submit s | watch s | cancel s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-11-06 | cd30429 | 0.10.0-DEV | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7332 | 24.06 | 2.27 | 0.35 | 1.35 | 1.67 | 1.6 | 1.68 | 1.75 |
| 2026-11-06 | e8bf825 | 0.10.0-DEV | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7374 | 15.31 | 1.5 | 0.26 | 0.97 | 1.19 | 1.16 | 1.2 | 1.29 |
| 2026-11-06 | 47a9242 | 0.10.0-DEV | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7660 | 22.57 | 2.33 | 0.37 | 1.35 | 1.64 | 1.58 | 1.63 | 1.77 |
| 2026-11-06 | 6ef3b66 | 0.10.0-DEV | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 23 | 7608 | 22.58 | 2.28 | 0.36 | 1.33 | 1.64 | 1.57 | 1.62 | 1.75 |
| 2026-11-07 | 6ef3b66 | 0.10.0-DEV | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 23 | 7608 | 13.47 | 1.41 | 0.23 | 0.91 | 1.07 | 1.04 | 1.07 | 1.16 |
| 2026-11-08 | 647a29c | 0.10.0-DEV | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 23 | 7608 | 22.57 | 2.3 | 0.33 | 1.37 | 1.67 | 1.6 | 1.66 | 1.85 |
| 2026-11-08 | 0843a87 | 0.10.0-DEV | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 22 | 7492 | 13.34 | 1.42 | 0.24 | 0.89 | 1.13 | 1.04 | 1.07 | 1.18 |
| 2026-11-09 | 0843a87 | 0.10.0-DEV | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 22 | 7492 | 14.22 | 1.46 | 0.23 | 0.97 | 1.15 | 1.07 | 1.12 | 1.15 |
| 2026-11-09 | 82be25d | 0.10.0-DEV | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 22 | 7798 | 16.06 | 1.59 | 0.27 | 1.06 | 1.28 | 1.19 | 1.28 | 1.29 |
| 2026-11-10 | ce0e2a0 | 0.10.0-DEV | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 22 | 7798 | 20.31 | 1.92 | 0.31 | 1.21 | 1.45 | 1.41 | 1.45 | 1.54 |
| 2026-11-10 | 1740bae | 0.10.0-DEV | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 22 | 7820 | 23.38 | 2.09 | 0.35 | 1.36 | 1.64 | 1.57 | 1.62 | 1.78 |
| 2026-11-10 | 2e4bc63 | 0.10.0-DEV | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 22 | 7823 | 20.31 | 1.87 | 0.3 | 1.14 | 1.39 | 1.34 | 1.37 | 1.49 |

</details>

<details>
<summary>nightly</summary>

| date | commit | version | julia | os | arch | src files | code lines | full s | pkg s | using s | help s | status s | submit s | watch s | cancel s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-11-06 | cd30429 | 0.10.0-DEV | 1.15.0-DEV.511 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7332 | 18.17 | 1.64 | 0.22 | 1.01 | 1.23 | 1.14 | 1.22 | 1.3 |
| 2026-11-06 | e8bf825 | 0.10.0-DEV | 1.15.0-DEV.512 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7374 | 24.12 | 2.15 | 0.26 | 1.25 | 1.55 | 1.44 | 1.56 | 1.63 |
| 2026-11-06 | 47a9242 | 0.10.0-DEV | 1.15.0-DEV.522 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7660 | 21.31 | 1.97 | 0.27 | 1.32 | 1.65 | 1.51 | 1.58 | 1.71 |
| 2026-11-06 | 6ef3b66 | 0.10.0-DEV | 1.15.0-DEV.537 | Ubuntu 26.04.1 LTS | x86_64 | 23 | 7608 | 22.65 | 2.16 | 0.25 | 1.27 | 1.55 | 1.52 | 1.54 | 1.68 |
| 2026-11-07 | 6ef3b66 | 0.10.0-DEV | 1.15.0-DEV.575 | Ubuntu 26.04.1 LTS | x86_64 | 23 | 7608 | 17.84 | 1.7 | 0.21 | 1.07 | 1.26 | 1.24 | 1.24 | 1.4 |
| 2026-11-08 | 647a29c | 0.10.0-DEV | 1.15.0-DEV.591 | Ubuntu 26.04.1 LTS | x86_64 | 23 | 7608 | 23.86 | 2.28 | 0.28 | 1.41 | 1.7 | 1.59 | 1.68 | 1.82 |
| 2026-11-08 | 0843a87 | 0.10.0-DEV | 1.15.0-DEV.603 | Ubuntu 26.04.1 LTS | x86_64 | 22 | 7492 | 20.72 | 1.91 | 0.26 | 1.27 | 1.55 | 1.49 | 1.54 | 1.67 |
| 2026-11-09 | 0843a87 | 0.10.0-DEV | 1.15.0-DEV.611 | Ubuntu 26.04.1 LTS | x86_64 | 22 | 7492 | 18.48 | 1.82 | 0.23 | 1.14 | 1.42 | 1.3 | 1.38 | 1.5 |
| 2026-11-09 | 82be25d | 0.10.0-DEV | 1.15.0-DEV.617 | Ubuntu 26.04.1 LTS | x86_64 | 22 | 7798 | 17.64 | 1.69 | 0.21 | 1.04 | 1.27 | 1.22 | 1.25 | 1.35 |
| 2026-11-10 | ce0e2a0 | 0.10.0-DEV | 1.15.0-DEV.632 | Ubuntu 26.04.1 LTS | x86_64 | 22 | 7798 | 19.22 | 1.7 | 0.21 | 1.03 | 1.24 | 1.16 | 1.23 | 1.36 |
| 2026-11-10 | 1740bae | 0.10.0-DEV | 1.15.0-DEV.632 | Ubuntu 26.04.1 LTS | x86_64 | 22 | 7820 | 26.21 | 2.25 | 0.29 | 1.34 | 1.61 | 1.53 | 1.6 | 1.73 |
| 2026-11-10 | 2e4bc63 | 0.10.0-DEV | 1.15.0-DEV.649 | Ubuntu 26.04.1 LTS | x86_64 | 22 | 7823 | 19.82 | 1.75 | 0.22 | 1.03 | 1.25 | 1.26 | 1.33 | 1.35 |

</details>

