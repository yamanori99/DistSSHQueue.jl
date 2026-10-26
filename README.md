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

- 1.13: julia 1.13.2 -> 1.13.3
- 1.13: status method new -> 657.3 ms: Tuple{DistSSHQueue.var"##show_status#217", Base.PipeEndpoint, Nothing, Bool, Nothing, Bool, typeof(D...
- 1.13: watch method new -> 691.0 ms: Tuple{DistSSHQueue.var"##watch!#221", Float64, Int64, Base.PipeEndpoint, Nothing, Bool, Nothing, Boo...
- 1.14-nightly: julia 1.14.0-alpha1.112 -> 1.14.0-alpha2
- 1.14-nightly: status method new -> 752.0 ms: Tuple{DistSSHQueue.var"##show_status#217", Base.PipeEndpoint, Nothing, Bool, Nothing, Bool, typeof(D...
- 1.14-nightly: watch method new -> 777.3 ms: Tuple{DistSSHQueue.var"##watch!#221", Float64, Int64, Base.PipeEndpoint, Nothing, Bool, Nothing, Boo...
- nightly: julia 1.15.0-DEV.132 -> 1.15.0-DEV.150
- nightly: status method new -> 660.8 ms: Tuple{DistSSHQueue.var"##show_status#217", Base.PipeEndpoint, Nothing, Bool, Nothing, Bool, typeof(D...
- nightly: watch method new -> 764.2 ms: Tuple{DistSSHQueue.var"##watch!#221", Float64, Int64, Base.PipeEndpoint, Nothing, Bool, Nothing, Boo...

<details open>
<summary>1.13</summary>

| date | commit | version | julia | os | arch | src files | code lines | full s | pkg s | using s | help s | status s | submit s | watch s | cancel s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-19 | 860266c | 0.9.6 | 1.13.2 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 7.76 | 1.93 | 0.32 | 1.02 | 5.62 | 6.47 | 5.64 | 5.88 |
| 2026-10-19 | fbd948c | 0.9.7 | 1.13.2 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 8.81 | 2.16 | 0.34 | 1.08 | 6.25 | 7.08 | 6.2 | 6.45 |
| 2026-10-20 | 59adc28 | 0.9.7 | 1.13.2 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 7.72 | 1.92 | 0.31 | 1.0 | 5.63 | 6.4 | 5.6 | 5.82 |
| 2026-10-20 | 6d3a5c7 | 0.9.7 | 1.13.2 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 9.34 | 2.28 | 0.36 | 1.16 | 6.52 | 7.45 | 6.41 | 6.67 |
| 2026-10-21 | 7c2c5df | 0.9.7 | 1.13.2 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6735 | 8.5 | 2.14 | 0.33 | 1.08 | 6.06 | 7.16 | 6.09 | 6.37 |
| 2026-10-22 | ff6d630 | 0.9.7 | 1.13.2 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6891 | 7.86 | 2.0 | 0.31 | 1.04 | 5.91 | 6.9 | 5.88 | 6.14 |
| 2026-10-22 | 6ae9bed | 0.9.7 | 1.13.2 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6891 | 9.17 | 2.32 | 0.34 | 1.14 | 6.64 | 7.64 | 6.36 | 6.8 |
| 2026-10-23 | 33f99d4 | 0.9.8 | 1.13.2 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7112 | 7.15 | 1.81 | 0.3 | 0.93 | 5.15 | 6.11 | 5.19 | 5.23 |
| 2026-10-24 | a7ddadc | 0.9.8 | 1.13.2 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7168 | 9.44 | 2.37 | 0.35 | 1.2 | 6.61 | 7.84 | 6.7 | 6.74 |
| 2026-10-25 | f957764 | 0.9.9 | 1.13.2 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7174 | 7.06 | 1.8 | 0.29 | 0.98 | 5.23 | 6.22 | 5.2 | 5.38 |
| 2026-10-26 | ebb72a5 | 0.9.10 | 1.13.2 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7216 | 5.78 | 1.47 | 0.23 | 2.59 | 5.09 | 5.21 | 5.23 | 5.32 |
| 2026-10-26 | 045acf7 | 0.9.10 | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7241 | 7.13 | 1.84 | 0.31 | 3.34 | 4.25 | 4.31 | 4.14 | 4.59 |

</details>

<details>
<summary>1.14-nightly</summary>

| date | commit | version | julia | os | arch | src files | code lines | full s | pkg s | using s | help s | status s | submit s | watch s | cancel s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-19 | 860266c | 0.9.6 | 1.14.0-DEV.3787 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 5.19 | 1.35 | 0.26 | 0.62 | 1.44 | 1.67 | 1.47 | 1.51 |
| 2026-10-19 | fbd948c | 0.9.7 | 1.14.0-DEV.3787 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 5.3 | 1.42 | 0.33 | 0.64 | 1.63 | 1.58 | 1.4 | 1.52 |
| 2026-10-20 | 59adc28 | 0.9.7 | 1.14.0-DEV.3787 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 5.6 | 1.48 | 0.28 | 0.68 | 1.59 | 1.74 | 1.4 | 1.63 |
| 2026-10-20 | 6d3a5c7 | 0.9.7 | 1.14.0-alpha1 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 7.79 | 2.03 | 0.35 | 0.78 | 2.01 | 2.22 | 1.96 | 2.06 |
| 2026-10-22 | 7c2c5df | 0.9.7 | 1.14.0-alpha1 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6735 | 6.2 | 1.67 | 0.28 | 0.62 | 1.6 | 1.83 | 1.59 | 1.71 |
| 2026-10-22 | ff6d630 | 0.9.7 | 1.14.0-alpha1 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6891 | 8.62 | 2.33 | 0.39 | 0.88 | 2.36 | 2.63 | 2.27 | 2.42 |
| 2026-10-22 | 6ae9bed | 0.9.7 | 1.14.0-alpha1 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6891 | 7.78 | 2.06 | 0.34 | 0.75 | 2.03 | 2.3 | 2.0 | 2.13 |
| 2026-10-23 | 33f99d4 | 0.9.8 | 1.14.0-alpha1 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7112 | 8.53 | 2.21 | 0.37 | 0.84 | 2.36 | 2.61 | 2.32 | 2.35 |
| 2026-10-24 | a7ddadc | 0.9.8 | 1.14.0-alpha1 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7168 | 8.37 | 2.2 | 0.36 | 0.81 | 2.18 | 2.57 | 2.2 | 2.28 |
| 2026-10-25 | f957764 | 0.9.9 | 1.14.0-alpha1.112 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7174 | 8.29 | 2.16 | 0.31 | 0.74 | 2.12 | 2.37 | 2.1 | 2.19 |
| 2026-10-26 | ebb72a5 | 0.9.10 | 1.14.0-alpha1.112 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7216 | 8.24 | 2.17 | 0.3 | 1.6 | 2.43 | 2.36 | 2.4 | 2.36 |
| 2026-10-26 | 045acf7 | 0.9.10 | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7241 | 8.47 | 2.21 | 0.31 | 1.63 | 2.03 | 1.88 | 2.03 | 2.12 |

</details>

<details>
<summary>nightly</summary>

| date | commit | version | julia | os | arch | src files | code lines | full s | pkg s | using s | help s | status s | submit s | watch s | cancel s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-19 | 860266c | 0.9.6 | 1.15.0-DEV.18 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 8.26 | 2.12 | 0.35 | 0.77 | 2.05 | 2.3 | 2.03 | 2.13 |
| 2026-10-19 | fbd948c | 0.9.7 | 1.15.0-DEV.18 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 8.16 | 2.1 | 0.36 | 0.77 | 2.03 | 2.34 | 2.01 | 2.16 |
| 2026-10-20 | 59adc28 | 0.9.7 | 1.15.0-DEV.29 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 8.35 | 2.13 | 0.37 | 0.83 | 2.17 | 2.46 | 2.2 | 2.31 |
| 2026-10-20 | 6d3a5c7 | 0.9.7 | 1.15.0-DEV.53 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 6.6 | 1.69 | 0.3 | 0.66 | 1.76 | 2.06 | 1.7 | 1.9 |
| 2026-10-22 | 7c2c5df | 0.9.7 | 1.15.0-DEV.71 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6735 | 8.61 | 2.28 | 0.36 | 0.83 | 2.21 | 2.43 | 2.16 | 2.26 |
| 2026-10-22 | ff6d630 | 0.9.7 | 1.15.0-DEV.71 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6891 | 5.49 | 1.49 | 0.27 | 0.59 | 1.52 | 1.81 | 1.54 | 1.64 |
| 2026-10-23 | 6ae9bed | 0.9.7 | 1.15.0-DEV.84 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6891 | 4.92 | 1.35 | 0.2 | 0.5 | 1.34 | 1.55 | 1.4 | 1.47 |
| 2026-10-23 | 33f99d4 | 0.9.8 | 1.15.0-DEV.104 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7112 | 8.37 | 2.19 | 0.31 | 0.76 | 2.15 | 2.48 | 2.12 | 2.25 |
| 2026-10-24 | a7ddadc | 0.9.8 | 1.15.0-DEV.126 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7168 | 5.41 | 1.42 | 0.21 | 0.57 | 1.51 | 1.74 | 1.42 | 1.47 |
| 2026-10-25 | f957764 | 0.9.9 | 1.15.0-DEV.132 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7174 | 8.25 | 2.11 | 0.23 | 0.69 | 2.1 | 2.52 | 2.04 | 2.08 |
| 2026-10-26 | ebb72a5 | 0.9.10 | 1.15.0-DEV.132 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7216 | 6.13 | 1.6 | 0.21 | 1.22 | 1.91 | 1.83 | 1.98 | 1.86 |
| 2026-10-26 | 045acf7 | 0.9.10 | 1.15.0-DEV.150 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7241 | 8.11 | 2.1 | 0.23 | 1.57 | 1.87 | 1.75 | 1.85 | 1.92 |

</details>

