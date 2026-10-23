# Compile bench

The charts are on [bench.html](https://yamanori99.github.io/DistSSHQueue.jl/bench.html).

Precompile time, load time, CLI wall time, `src/**/*.jl` size, and the host
(OS name, arch, CPU). `code lines` skips blank lines. A row is flagged when,
against the previous sample on the same Julia slot, the host OS or arch
changes, the Julia version changes, package precompile grows by 1.5x and 0.5s, a command wall grows
by 1.5x and 1s, or a method of at least 200 ms is new in the top 20 or
doubles. This does not fail CI.

## Flagged

- 1.13: host changed Ubuntu 24.04.5 LTS x86_64 -> Ubuntu 26.04.1 LTS x86_64
- 1.13: status method new -> 749.4 ms: Tuple{DistSSHQueue.var"##show_status#216", Base.PipeEndpoint, Nothing, Bool, Nothing, Bool, typeof(D...
- 1.13: watch method new -> 750.5 ms: Tuple{DistSSHQueue.var"##watch!#220", Float64, Int64, Base.PipeEndpoint, Nothing, Bool, Nothing, Boo...
- 1.14-nightly: host changed Ubuntu 24.04.5 LTS x86_64 -> Ubuntu 26.04.1 LTS x86_64
- 1.14-nightly: status method new -> 789.2 ms: Tuple{DistSSHQueue.var"##show_status#216", Base.PipeEndpoint, Nothing, Bool, Nothing, Bool, typeof(D...
- 1.14-nightly: watch method new -> 857.0 ms: Tuple{DistSSHQueue.var"##watch!#220", Float64, Int64, Base.PipeEndpoint, Nothing, Bool, Nothing, Boo...
- nightly: host changed Ubuntu 24.04.5 LTS x86_64 -> Ubuntu 26.04.1 LTS x86_64
- nightly: julia 1.15.0-DEV.84 -> 1.15.0-DEV.104
- nightly: package precompile 1.35s -> 2.19s
- nightly: status method new -> 754.3 ms: Tuple{DistSSHQueue.var"##show_status#216", Base.PipeEndpoint, Nothing, Bool, Nothing, Bool, typeof(D...
- nightly: watch method new -> 831.5 ms: Tuple{DistSSHQueue.var"##watch!#220", Float64, Int64, Base.PipeEndpoint, Nothing, Bool, Nothing, Boo...

## 1.13

| date | commit | version | julia | os | arch | src files | code lines | full s | pkg s | using s | help s | status s | submit s | watch s | cancel s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-18 | 2ad75fb | 0.9.6 | 1.13.2 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6144 | 8.35 | 1.74 | 0.32 | 14.66 | 15.43 |  |  |  |
| 2026-10-18 | de4ef6e | 0.9.6 | 1.13.2 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6181 | 9.24 | 2.28 | 0.36 | 1.15 | 6.52 | 7.38 | 6.55 | 6.92 |
| 2026-10-19 | 860266c | 0.9.6 | 1.13.2 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 7.76 | 1.93 | 0.32 | 1.02 | 5.62 | 6.47 | 5.64 | 5.88 |
| 2026-10-19 | fbd948c | 0.9.7 | 1.13.2 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 8.81 | 2.16 | 0.34 | 1.08 | 6.25 | 7.08 | 6.2 | 6.45 |
| 2026-10-20 | 59adc28 | 0.9.7 | 1.13.2 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 7.72 | 1.92 | 0.31 | 1.0 | 5.63 | 6.4 | 5.6 | 5.82 |
| 2026-10-20 | 6d3a5c7 | 0.9.7 | 1.13.2 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 9.34 | 2.28 | 0.36 | 1.16 | 6.52 | 7.45 | 6.41 | 6.67 |
| 2026-10-21 | 7c2c5df | 0.9.7 | 1.13.2 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6735 | 8.5 | 2.14 | 0.33 | 1.08 | 6.06 | 7.16 | 6.09 | 6.37 |
| 2026-10-22 | ff6d630 | 0.9.7 | 1.13.2 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6891 | 7.86 | 2.0 | 0.31 | 1.04 | 5.91 | 6.9 | 5.88 | 6.14 |
| 2026-10-22 | 6ae9bed | 0.9.7 | 1.13.2 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6891 | 9.17 | 2.32 | 0.34 | 1.14 | 6.64 | 7.64 | 6.36 | 6.8 |
| 2026-10-23 | 33f99d4 | 0.9.8 | 1.13.2 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7112 | 7.15 | 1.81 | 0.3 | 0.93 | 5.15 | 6.11 | 5.19 | 5.23 |

## 1.14-nightly

| date | commit | version | julia | os | arch | src files | code lines | full s | pkg s | using s | help s | status s | submit s | watch s | cancel s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-18 | 2ad75fb | 0.9.6 | 1.14.0-DEV.3787 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6144 | 4.42 | 0.98 | 0.24 | 4.2 | 4.33 |  |  |  |
| 2026-10-18 | de4ef6e | 0.9.6 | 1.14.0-DEV.3787 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6181 | 6.96 | 1.84 | 0.33 | 0.71 | 1.82 | 2.12 | 1.76 | 1.93 |
| 2026-10-19 | 860266c | 0.9.6 | 1.14.0-DEV.3787 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 5.19 | 1.35 | 0.26 | 0.62 | 1.44 | 1.67 | 1.47 | 1.51 |
| 2026-10-19 | fbd948c | 0.9.7 | 1.14.0-DEV.3787 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 5.3 | 1.42 | 0.33 | 0.64 | 1.63 | 1.58 | 1.4 | 1.52 |
| 2026-10-20 | 59adc28 | 0.9.7 | 1.14.0-DEV.3787 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 5.6 | 1.48 | 0.28 | 0.68 | 1.59 | 1.74 | 1.4 | 1.63 |
| 2026-10-20 | 6d3a5c7 | 0.9.7 | 1.14.0-alpha1 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 7.79 | 2.03 | 0.35 | 0.78 | 2.01 | 2.22 | 1.96 | 2.06 |
| 2026-10-22 | 7c2c5df | 0.9.7 | 1.14.0-alpha1 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6735 | 6.2 | 1.67 | 0.28 | 0.62 | 1.6 | 1.83 | 1.59 | 1.71 |
| 2026-10-22 | ff6d630 | 0.9.7 | 1.14.0-alpha1 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6891 | 8.62 | 2.33 | 0.39 | 0.88 | 2.36 | 2.63 | 2.27 | 2.42 |
| 2026-10-22 | 6ae9bed | 0.9.7 | 1.14.0-alpha1 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6891 | 7.78 | 2.06 | 0.34 | 0.75 | 2.03 | 2.3 | 2.0 | 2.13 |
| 2026-10-23 | 33f99d4 | 0.9.8 | 1.14.0-alpha1 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7112 | 8.53 | 2.21 | 0.37 | 0.84 | 2.36 | 2.61 | 2.32 | 2.35 |

## nightly

| date | commit | version | julia | os | arch | src files | code lines | full s | pkg s | using s | help s | status s | submit s | watch s | cancel s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-18 | de4ef6e | 0.9.6 | 1.14.0-DEV.3787 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6181 | 7.99 | 2.09 | 0.35 | 0.77 | 2.0 | 2.24 | 1.95 | 2.14 |
| 2026-10-19 | 860266c | 0.9.6 | 1.15.0-DEV.18 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 8.26 | 2.12 | 0.35 | 0.77 | 2.05 | 2.3 | 2.03 | 2.13 |
| 2026-10-19 | fbd948c | 0.9.7 | 1.15.0-DEV.18 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 8.16 | 2.1 | 0.36 | 0.77 | 2.03 | 2.34 | 2.01 | 2.16 |
| 2026-10-20 | 59adc28 | 0.9.7 | 1.15.0-DEV.29 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 8.35 | 2.13 | 0.37 | 0.83 | 2.17 | 2.46 | 2.2 | 2.31 |
| 2026-10-20 | 6d3a5c7 | 0.9.7 | 1.15.0-DEV.53 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 6.6 | 1.69 | 0.3 | 0.66 | 1.76 | 2.06 | 1.7 | 1.9 |
| 2026-10-22 | 7c2c5df | 0.9.7 | 1.15.0-DEV.71 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6735 | 8.61 | 2.28 | 0.36 | 0.83 | 2.21 | 2.43 | 2.16 | 2.26 |
| 2026-10-22 | ff6d630 | 0.9.7 | 1.15.0-DEV.71 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6891 | 5.49 | 1.49 | 0.27 | 0.59 | 1.52 | 1.81 | 1.54 | 1.64 |
| 2026-10-23 | 6ae9bed | 0.9.7 | 1.15.0-DEV.84 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6891 | 4.92 | 1.35 | 0.2 | 0.5 | 1.34 | 1.55 | 1.4 | 1.47 |
| 2026-10-23 | 33f99d4 | 0.9.8 | 1.15.0-DEV.104 | Ubuntu 26.04.1 LTS | x86_64 | 24 | 7112 | 8.37 | 2.19 | 0.31 | 0.76 | 2.15 | 2.48 | 2.12 | 2.25 |

