# Compile bench

Precompile time, load time, CLI wall time, `src/**/*.jl` size, and the host
(OS name, arch, CPU). `code lines` skips blank lines. A row is flagged when,
against the previous sample on the same Julia slot, the host OS or arch
changes, the Julia version changes, package precompile grows by 1.5x and 0.5s, a command wall grows
by 1.5x and 1s, or a method of at least 200 ms is new in the top 20 or
doubles. This does not fail CI.

## Flagged

- 1.13: status method new -> 836.0 ms: Tuple{DistSSHQueue.var"##show_status#195", Base.PipeEndpoint, Nothing, Bool, Nothing, Bool, typeof(D...
- 1.13: watch method new -> 864.3 ms: Tuple{DistSSHQueue.var"##watch!#199", Float64, Int64, Base.PipeEndpoint, Nothing, Bool, Nothing, Boo...
- nightly: julia 1.14.0-DEV.3787 -> 1.15.0-DEV.18
- nightly: status method new -> 786.2 ms: Tuple{DistSSHQueue.var"##show_status#195", Base.PipeEndpoint, Nothing, Bool, Nothing, Bool, typeof(D...
- nightly: watch method new -> 816.1 ms: Tuple{DistSSHQueue.var"##watch!#199", Float64, Int64, Base.PipeEndpoint, Nothing, Bool, Nothing, Boo...

## 1.13

| date | commit | version | julia | os | arch | src files | code lines | full s | pkg s | using s | help s | status s | submit s | watch s | cancel s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-18 | 2ad75fb | 0.9.6 | 1.13.2 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6144 | 8.35 | 1.74 | 0.32 | 14.66 | 15.43 |  |  |  |
| 2026-10-18 | de4ef6e | 0.9.6 | 1.13.2 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6181 | 9.24 | 2.28 | 0.36 | 1.15 | 6.52 | 7.38 | 6.55 | 6.92 |
| 2026-10-19 | 860266c | 0.9.6 | 1.13.2 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 7.76 | 1.93 | 0.32 | 1.02 | 5.62 | 6.47 | 5.64 | 5.88 |

```mermaid
---
config:
  theme: base
  themeVariables:
    xyChart:
      plotColorPalette: "#1f4e79"
  xyChart:
    xAxis:
      labelRotation: 45
---
xychart-beta
    title "1.13 help"
    x-axis ["10-18 2ad75fb", "10-18 de4ef6e", "10-19 860266c"]
    y-axis "seconds" 0 --> 18
    line [14.66, 1.15, 1.02]
```


Latest `help` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(DistSSHQueue.main), Array{String, 1}}` | 457.5 | 536.3 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:topic,), Tuple{Nothing}}, typeof(DistSSHQueue.prin...` | 49.9 | 57.2 |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 17.4 | 20.2 |
| `Tuple{typeof(Base.should_use_main_entrypoint)}` | 12.8 | 11.8 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:topic,), Tuple{Nothing}}, typeof(DistSSHQueue.prin...` | 4.2 | 5.1 |
| `Tuple{typeof(Base.getproperty), Base.Set{String}, Symbol}` | 3.5 | 4.1 |
| `Tuple{typeof(Base.something), Nothing, Symbol}` | 3.5 | 3.3 |
| `Tuple{typeof(Base.getproperty), Base.GenericCondition{Base.ReentrantLock}, Symbol}` | 3.4 | 3.6 |
| `Tuple{typeof(Base._cshp), Int64, Tuple{Bool}, Tuple{}, Tuple{Int64}}` | 3.2 | 3.8 |

```mermaid
---
config:
  theme: base
  themeVariables:
    xyChart:
      plotColorPalette: "#1f4e79"
  xyChart:
    xAxis:
      labelRotation: 45
---
xychart-beta
    title "1.13 status"
    x-axis ["10-18 2ad75fb", "10-18 de4ef6e", "10-19 860266c"]
    y-axis "seconds" 0 --> 19
    line [15.43, 6.52, 5.62]
```


Latest `status` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{DistSSHQueue.var"#_entry_forward##0#_entry_forward##1"{DistSSHQueue.var"#_argv##0#_a...` | 3811.1 | 4424.5 |
| `Tuple{DistSSHQueue.var"##show_status#195", Base.PipeEndpoint, Nothing, Bool, Nothing, Bool...` | 836.0 |  |
| `Tuple{typeof(DistSSHQueue.main), Array{String, 1}}` | 465.4 | 519.6 |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 17.7 | 21.1 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:quiet, :tail, :verbose), Tuple{Bool, Nothing, Bool...` | 13.0 | 14.2 |
| `Tuple{typeof(Base.should_use_main_entrypoint)}` | 12.7 | 11.6 |
| `Tuple{typeof(Base._array_for), Type{DistSSHQueue.Job}, Array{Any, 1}, Base.HasShape{1}}` | 6.3 | 7.7 |
| `Tuple{typeof(Base.getproperty), NamedTuple{(:quiet, :progress, :verbose, :yes, :hosts_file...` | 5.5 | 5.4 |
| `Tuple{Dates.var"##34#35", Vararg{Any, 5}}` | 4.5 | 5.0 |
| `Tuple{typeof(Base.map), Base.var"#append!##0#append!##1"{String}, NTuple{10, String}}` | 4.3 | 4.7 |

```mermaid
---
config:
  theme: base
  themeVariables:
    xyChart:
      plotColorPalette: "#1f4e79"
  xyChart:
    xAxis:
      labelRotation: 45
---
xychart-beta
    title "1.13 submit"
    x-axis ["10-18 de4ef6e", "10-19 860266c"]
    y-axis "seconds" 0 --> 9
    line [7.38, 6.47]
```


Latest `submit` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{DistSSHQueue.var"#_entry_forward##0#_entry_forward##1"{DistSSHQueue.var"#_argv##0#_a...` | 4545.9 | 5261.4 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:kind, :quiet, :verbosity), Tuple{Symbol, Bool, Str...` | 508.2 | 577.6 |
| `Tuple{typeof(DistSSHQueue.main), Array{String, 1}}` | 456.5 | 523.5 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:kind,), Tuple{Symbol}}, typeof(DistSSHQueue.submit...` | 103.6 | 116.0 |
| `Tuple{typeof(DistSSHQueue.script_arg), String, String}` | 82.3 | 96.4 |
| `Tuple{typeof(DistSSHQueue.reject_worker_root_collision!), Array{DistSSHQueue.Job, 1}, Stri...` | 59.4 | 64.3 |
| `Tuple{typeof(DistSSHQueue.parse_host_cap), String}` | 44.5 | 51.8 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:kind,), Tuple{Symbol}}, typeof(DistSSHQueue.submit...` | 21.0 | 23.8 |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 17.5 | 19.4 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:indent, :sorted, :by, :inline_tables), Tuple{Int64...` | 13.9 | 16.9 |

```mermaid
---
config:
  theme: base
  themeVariables:
    xyChart:
      plotColorPalette: "#1f4e79"
  xyChart:
    xAxis:
      labelRotation: 45
---
xychart-beta
    title "1.13 watch"
    x-axis ["10-18 de4ef6e", "10-19 860266c"]
    y-axis "seconds" 0 --> 8
    line [6.55, 5.64]
```


Latest `watch` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{DistSSHQueue.var"#_entry_forward##0#_entry_forward##1"{DistSSHQueue.var"#_argv##0#_a...` | 3785.7 | 4415.9 |
| `Tuple{DistSSHQueue.var"##watch!#199", Float64, Int64, Base.PipeEndpoint, Nothing, Bool, No...` | 864.3 |  |
| `Tuple{typeof(DistSSHQueue.main), Array{String, 1}}` | 457.7 | 541.3 |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 17.4 | 19.5 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:interval, :ticks, :quiet, :tail, :verbose), Tuple{...` | 16.1 | 18.1 |
| `Tuple{typeof(Base.should_use_main_entrypoint)}` | 12.4 | 13.5 |
| `Tuple{typeof(Base._array_for), Type{DistSSHQueue.Job}, Array{Any, 1}, Base.HasShape{1}}` | 6.3 | 7.6 |
| `Tuple{typeof(Base.getproperty), NamedTuple{(:quiet, :progress, :verbose, :yes, :hosts_file...` | 5.4 | 5.5 |
| `Tuple{Dates.var"##34#35", Vararg{Any, 5}}` | 4.5 | 4.9 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:read, :write, :append, :truncate), Tuple{Bool, Boo...` | 4.1 |  |

```mermaid
---
config:
  theme: base
  themeVariables:
    xyChart:
      plotColorPalette: "#1f4e79"
  xyChart:
    xAxis:
      labelRotation: 45
---
xychart-beta
    title "1.13 cancel"
    x-axis ["10-18 de4ef6e", "10-19 860266c"]
    y-axis "seconds" 0 --> 9
    line [6.92, 5.88]
```


Latest `cancel` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{DistSSHQueue.var"#_entry_forward##0#_entry_forward##1"{DistSSHQueue.var"#_argv##0#_a...` | 4622.3 | 5472.3 |
| `Tuple{typeof(DistSSHQueue.main), Array{String, 1}}` | 452.3 | 528.3 |
| `Tuple{typeof(DistSSHQueue._row_dt), String, String}` | 76.2 | 90.6 |
| `Tuple{typeof(DistSSHQueue._job_row), Base.Dict{String, Any}, String}` | 51.6 | 62.6 |
| `Tuple{Type{Base.Dict{String, Any}}, Base.Generator{Base.Dict{String, Any}, DistSSHQueue.va...` | 27.3 | 31.0 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:id, :kind, :script, :hosts, :state, :queued_at, :s...` | 21.0 | 24.1 |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 17.7 | 20.9 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:indent, :sorted, :by, :inline_tables), Tuple{Int64...` | 13.9 | 17.7 |
| `Tuple{typeof(Base.should_use_main_entrypoint)}` | 12.4 | 11.7 |
| `Tuple{typeof(Base.iterate), Base.Dict{String, Any}}` | 10.2 | 12.2 |

## 1.14-nightly

| date | commit | version | julia | os | arch | src files | code lines | full s | pkg s | using s | help s | status s | submit s | watch s | cancel s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-18 | 2ad75fb | 0.9.6 | 1.14.0-DEV.3787 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6144 | 4.42 | 0.98 | 0.24 | 4.2 | 4.33 |  |  |  |
| 2026-10-18 | de4ef6e | 0.9.6 | 1.14.0-DEV.3787 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6181 | 6.96 | 1.84 | 0.33 | 0.71 | 1.82 | 2.12 | 1.76 | 1.93 |
| 2026-10-19 | 860266c | 0.9.6 | 1.14.0-DEV.3787 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 5.19 | 1.35 | 0.26 | 0.62 | 1.44 | 1.67 | 1.47 | 1.51 |
| 2026-10-19 | fbd948c | 0.9.7 | 1.14.0-DEV.3787 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 5.3 | 1.42 | 0.33 | 0.64 | 1.63 | 1.58 | 1.4 | 1.52 |

```mermaid
---
config:
  theme: base
  themeVariables:
    xyChart:
      plotColorPalette: "#1f4e79"
  xyChart:
    xAxis:
      labelRotation: 45
---
xychart-beta
    title "1.14-nightly 1.14-DEV.3787 help"
    x-axis ["10-18 1.14-DEV.3787", "10-18 de4ef6e", "10-19 860266c", "10-19 v0.9.7"]
    y-axis "seconds" 0 --> 6
    line [4.2, 0.71, 0.62, 0.64]
```


Latest `help` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(DistSSHQueue.main), Array{String, 1}}` | 360.3 | 352.9 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:topic,), Tuple{Nothing}}, typeof(DistSSHQueue.prin...` | 38.6 | 39.2 |
| `Tuple{typeof(Distributed.flush_gc_msgs)}` | 17.8 | 18.1 |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 12.0 | 12.3 |
| `Tuple{typeof(Base.should_use_main_entrypoint)}` | 11.8 | 12.1 |
| `Tuple{typeof(Base.string), Char}` | 6.1 | 6.1 |
| `Tuple{typeof(Base.tail), NTuple{15, String}}` | 5.1 | 5.1 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:topic,), Tuple{Nothing}}, typeof(DistSSHQueue.prin...` | 4.5 | 4.7 |
| `Tuple{typeof(Base.tail), NTuple{14, String}}` | 4.2 | 3.9 |
| `Tuple{typeof(Base._cshp), Int64, Tuple{Bool}, Tuple{}, Tuple{Int64}}` | 4.1 | 3.9 |

```mermaid
---
config:
  theme: base
  themeVariables:
    xyChart:
      plotColorPalette: "#1f4e79"
  xyChart:
    xAxis:
      labelRotation: 45
---
xychart-beta
    title "1.14-nightly 1.14-DEV.3787 status"
    x-axis ["10-18 1.14-DEV.3787", "10-18 de4ef6e", "10-19 860266c", "10-19 v0.9.7"]
    y-axis "seconds" 0 --> 6
    line [4.33, 1.82, 1.44, 1.63]
```


Latest `status` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{DistSSHQueue.var"#_entry_forward##0#_entry_forward##1"{DistSSHQueue.var"#_argv##0#_a...` | 3180.0 | 2997.6 |
| `Tuple{DistSSHQueue.var"##show_status#195", Base.PipeEndpoint, Nothing, Bool, Nothing, Bool...` | 595.9 | 542.1 |
| `Tuple{typeof(DistSSHQueue.main), Array{String, 1}}` | 173.4 | 172.1 |
| `Tuple{typeof(Distributed.flush_gc_msgs)}` | 18.8 | 17.7 |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 12.2 | 11.5 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:quiet, :tail, :verbose), Tuple{Bool, Nothing, Bool...` | 9.7 | 9.3 |
| `Tuple{typeof(Base.getproperty), NamedTuple{(:quiet, :progress, :verbose, :yes, :hosts_file...` | 8.0 | 7.8 |
| `Tuple{typeof(Base.map), Base.var"#append!##0#append!##1"{String}, NTuple{10, String}}` | 7.0 | 6.4 |
| `Tuple{typeof(Base._array_for), Core.TypeEgal{DistSSHQueue.Job}, Array{Any, 1}, Base.HasSha...` | 6.7 | 6.2 |
| `Tuple{typeof(DistSSHQueue._q_cell), String, Int64}` | 5.1 | 5.0 |

```mermaid
---
config:
  theme: base
  themeVariables:
    xyChart:
      plotColorPalette: "#1f4e79"
  xyChart:
    xAxis:
      labelRotation: 45
---
xychart-beta
    title "1.14-nightly 1.14-DEV.3787 submit"
    x-axis ["10-18 1.14-DEV.3787", "10-19 860266c", "10-19 v0.9.7"]
    y-axis "seconds" 0 --> 3
    line [2.12, 1.67, 1.58]
```


Latest `submit` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{DistSSHQueue.var"#_entry_forward##0#_entry_forward##1"{DistSSHQueue.var"#_argv##0#_a...` | 3639.0 | 3624.4 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:kind, :quiet, :verbosity), Tuple{Symbol, Bool, Str...` | 341.5 | 345.9 |
| `Tuple{typeof(DistSSHQueue.main), Array{String, 1}}` | 168.3 | 167.7 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:kind,), Tuple{Symbol}}, typeof(DistSSHQueue.submit...` | 69.8 | 72.1 |
| `Tuple{typeof(DistSSHQueue.script_arg), String, String}` | 55.6 | 56.8 |
| `Tuple{typeof(DistSSHQueue.reject_worker_root_collision!), Array{DistSSHQueue.Job, 1}, Stri...` | 48.1 | 46.9 |
| `Tuple{typeof(DistSSHQueue.parse_host_cap), String}` | 32.3 | 33.5 |
| `Tuple{typeof(Distributed.flush_gc_msgs)}` | 17.4 | 17.5 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:kind,), Tuple{Symbol}}, typeof(DistSSHQueue.submit...` | 17.0 | 17.1 |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 10.5 | 11.6 |

```mermaid
---
config:
  theme: base
  themeVariables:
    xyChart:
      plotColorPalette: "#1f4e79"
  xyChart:
    xAxis:
      labelRotation: 45
---
xychart-beta
    title "1.14-nightly 1.14-DEV.3787 watch"
    x-axis ["10-18 1.14-DEV.3787", "10-19 860266c", "10-19 v0.9.7"]
    y-axis "seconds" 0 --> 3
    line [1.76, 1.47, 1.4]
```


Latest `watch` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{DistSSHQueue.var"#_entry_forward##0#_entry_forward##1"{DistSSHQueue.var"#_argv##0#_a...` | 2816.1 | 2898.8 |
| `Tuple{DistSSHQueue.var"##watch!#199", Float64, Int64, Base.PipeEndpoint, Nothing, Bool, No...` | 554.0 | 597.0 |
| `Tuple{typeof(DistSSHQueue.main), Array{String, 1}}` | 162.0 | 172.1 |
| `Tuple{typeof(Distributed.flush_gc_msgs)}` | 16.6 | 18.2 |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 11.6 | 12.2 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:interval, :ticks, :quiet, :tail, :verbose), Tuple{...` | 11.5 | 12.6 |
| `Tuple{Core.TypeEgal{NamedTuple{(:verb, :default_interval), T} where T<:Tuple}, Tuple{Strin...` | 6.6 | 6.2 |
| `Tuple{typeof(Base.should_use_main_entrypoint)}` | 2.9 | 3.0 |
| `Tuple{Base.var"##187#188", Vararg{Any, 4}}` | 2.9 | 2.9 |
| `Tuple{typeof(Base._array_for), Core.TypeEgal{DistSSHQueue.Job}, Array{Any, 1}, Base.HasSha...` | 1.7 | 1.8 |

```mermaid
---
config:
  theme: base
  themeVariables:
    xyChart:
      plotColorPalette: "#1f4e79"
  xyChart:
    xAxis:
      labelRotation: 45
---
xychart-beta
    title "1.14-nightly 1.14-DEV.3787 cancel"
    x-axis ["10-18 1.14-DEV.3787", "10-19 860266c", "10-19 v0.9.7"]
    y-axis "seconds" 0 --> 3
    line [1.93, 1.51, 1.52]
```


Latest `cancel` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{DistSSHQueue.var"#_entry_forward##0#_entry_forward##1"{DistSSHQueue.var"#_argv##0#_a...` | 3562.0 | 3560.7 |
| `Tuple{typeof(DistSSHQueue.main), Array{String, 1}}` | 156.9 | 162.5 |
| `Tuple{typeof(DistSSHQueue._job_row), Base.Dict{String, Any}, String}` | 120.9 | 116.8 |
| `Tuple{typeof(DistSSHQueue._row_dt), String, String}` | 52.3 | 52.0 |
| `Tuple{Core.TypeEgal{Base.Dict{String, Any}}, Base.Generator{Base.Dict{String, Any}, DistSS...` | 21.7 | 21.3 |
| `Tuple{typeof(Distributed.flush_gc_msgs)}` | 19.6 | 17.6 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:id, :kind, :script, :hosts, :state, :queued_at, :s...` | 17.5 | 17.5 |
| `Tuple{Core.TypeEgal{Base.Dict{String, Any}}, Pair{String, String}, Pair{String, String}, P...` | 12.3 | 12.5 |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 12.0 | 11.6 |
| `Tuple{typeof(Base.iterate), Base.Dict{String, Any}}` | 10.3 | 10.1 |

## nightly

| date | commit | version | julia | os | arch | src files | code lines | full s | pkg s | using s | help s | status s | submit s | watch s | cancel s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-18 | de4ef6e | 0.9.6 | 1.14.0-DEV.3787 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6181 | 7.99 | 2.09 | 0.35 | 0.77 | 2.0 | 2.24 | 1.95 | 2.14 |
| 2026-10-19 | 860266c | 0.9.6 | 1.15.0-DEV.18 | Ubuntu 24.04.5 LTS | x86_64 | 24 | 6182 | 8.26 | 2.12 | 0.35 | 0.77 | 2.05 | 2.3 | 2.03 | 2.13 |

```mermaid
---
config:
  theme: base
  themeVariables:
    xyChart:
      plotColorPalette: "#1f4e79"
  xyChart:
    xAxis:
      labelRotation: 45
---
xychart-beta
    title "nightly 1.15-DEV.18 help"
    x-axis ["10-18 1.14-DEV.3787", "10-19 julia 1.15-DEV.18"]
    y-axis "seconds" 0 --> 1
    line [0.77, 0.77]
```


Latest `help` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(DistSSHQueue.main), Array{String, 1}}` | 473.7 | 455.3 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:topic,), Tuple{Nothing}}, typeof(DistSSHQueue.prin...` | 52.2 | 50.9 |
| `Tuple{typeof(Distributed.flush_gc_msgs)}` | 23.0 | 22.0 |
| `Tuple{typeof(Base.should_use_main_entrypoint)}` | 15.5 | 15.0 |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 14.8 | 14.0 |
| `Tuple{typeof(Base.string), Char}` | 6.5 | 6.2 |
| `Tuple{typeof(Base.tail), NTuple{15, String}}` | 5.3 | 4.5 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:topic,), Tuple{Nothing}}, typeof(DistSSHQueue.prin...` | 4.7 | 4.1 |
| `Tuple{typeof(Base.tail), NTuple{12, String}}` | 4.1 | 3.8 |
| `Tuple{typeof(Base.tail), NTuple{13, String}}` | 4.0 | 3.8 |

```mermaid
---
config:
  theme: base
  themeVariables:
    xyChart:
      plotColorPalette: "#1f4e79"
  xyChart:
    xAxis:
      labelRotation: 45
---
xychart-beta
    title "nightly 1.15-DEV.18 status"
    x-axis ["10-18 1.14-DEV.3787", "10-19 julia 1.15-DEV.18"]
    y-axis "seconds" 0 --> 3
    line [2.0, 2.05]
```


Latest `status` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{DistSSHQueue.var"#_entry_forward##0#_entry_forward##1"{DistSSHQueue.var"#_argv##0#_a...` | 4318.7 | 4199.3 |
| `Tuple{DistSSHQueue.var"##show_status#195", Base.PipeEndpoint, Nothing, Bool, Nothing, Bool...` | 786.2 |  |
| `Tuple{typeof(DistSSHQueue.main), Array{String, 1}}` | 213.4 | 203.3 |
| `Tuple{typeof(Distributed.flush_gc_msgs)}` | 22.2 | 23.3 |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 14.1 | 14.4 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:quiet, :tail, :verbose), Tuple{Bool, Nothing, Bool...` | 10.6 | 10.7 |
| `Tuple{typeof(Base.getproperty), NamedTuple{(:quiet, :progress, :verbose, :yes, :hosts_file...` | 9.0 | 8.7 |
| `Tuple{typeof(Base.map), Base.var"#append!##0#append!##1"{String}, NTuple{10, String}}` | 7.1 | 6.9 |
| `Tuple{typeof(Base._array_for), Core.TypeEgal{DistSSHQueue.Job}, Array{Any, 1}, Base.HasSha...` | 7.0 | 7.0 |
| `Tuple{typeof(DistSSHQueue._q_cell), String, Int64}` | 5.1 | 5.0 |

```mermaid
---
config:
  theme: base
  themeVariables:
    xyChart:
      plotColorPalette: "#1f4e79"
  xyChart:
    xAxis:
      labelRotation: 45
---
xychart-beta
    title "nightly 1.15-DEV.18 submit"
    x-axis ["10-18 1.14-DEV.3787", "10-19 julia 1.15-DEV.18"]
    y-axis "seconds" 0 --> 3
    line [2.24, 2.3]
```


Latest `submit` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{DistSSHQueue.var"#_entry_forward##0#_entry_forward##1"{DistSSHQueue.var"#_argv##0#_a...` | 5098.0 | 5069.4 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:kind, :quiet, :verbosity), Tuple{Symbol, Bool, Str...` | 493.8 | 491.7 |
| `Tuple{typeof(DistSSHQueue.main), Array{String, 1}}` | 234.8 | 212.0 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:kind,), Tuple{Symbol}}, typeof(DistSSHQueue.submit...` | 95.9 | 94.5 |
| `Tuple{typeof(DistSSHQueue.script_arg), String, String}` | 82.0 | 80.8 |
| `Tuple{typeof(DistSSHQueue.reject_worker_root_collision!), Array{DistSSHQueue.Job, 1}, Stri...` | 67.0 | 66.8 |
| `Tuple{typeof(DistSSHQueue.parse_host_cap), String}` | 47.2 | 45.8 |
| `Tuple{typeof(Distributed.flush_gc_msgs)}` | 22.5 | 22.7 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:kind,), Tuple{Symbol}}, typeof(DistSSHQueue.submit...` | 21.1 | 20.5 |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 14.0 | 14.1 |

```mermaid
---
config:
  theme: base
  themeVariables:
    xyChart:
      plotColorPalette: "#1f4e79"
  xyChart:
    xAxis:
      labelRotation: 45
---
xychart-beta
    title "nightly 1.15-DEV.18 watch"
    x-axis ["10-18 1.14-DEV.3787", "10-19 julia 1.15-DEV.18"]
    y-axis "seconds" 0 --> 3
    line [1.95, 2.03]
```


Latest `watch` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{DistSSHQueue.var"#_entry_forward##0#_entry_forward##1"{DistSSHQueue.var"#_argv##0#_a...` | 4221.6 | 4086.9 |
| `Tuple{DistSSHQueue.var"##watch!#199", Float64, Int64, Base.PipeEndpoint, Nothing, Bool, No...` | 816.1 |  |
| `Tuple{typeof(DistSSHQueue.main), Array{String, 1}}` | 217.1 | 214.5 |
| `Tuple{typeof(Distributed.flush_gc_msgs)}` | 23.1 | 22.8 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:interval, :ticks, :quiet, :tail, :verbose), Tuple{...` | 14.9 | 15.2 |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 14.9 | 14.9 |
| `Tuple{Core.TypeEgal{NamedTuple{(:verb, :default_interval), T} where T<:Tuple}, Tuple{Strin...` | 6.6 | 6.6 |
| `Tuple{Base.var"##187#188", Vararg{Any, 4}}` | 3.8 | 3.8 |
| `Tuple{typeof(Base.should_use_main_entrypoint)}` | 2.9 | 2.8 |
| `Tuple{typeof(Base._array_for), Core.TypeEgal{DistSSHQueue.Job}, Array{Any, 1}, Base.HasSha...` | 1.9 | 37.3 |

```mermaid
---
config:
  theme: base
  themeVariables:
    xyChart:
      plotColorPalette: "#1f4e79"
  xyChart:
    xAxis:
      labelRotation: 45
---
xychart-beta
    title "nightly 1.15-DEV.18 cancel"
    x-axis ["10-18 1.14-DEV.3787", "10-19 julia 1.15-DEV.18"]
    y-axis "seconds" 0 --> 3
    line [2.14, 2.13]
```


Latest `cancel` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{DistSSHQueue.var"#_entry_forward##0#_entry_forward##1"{DistSSHQueue.var"#_argv##0#_a...` | 5081.8 | 5126.5 |
| `Tuple{typeof(DistSSHQueue.main), Array{String, 1}}` | 218.5 | 212.5 |
| `Tuple{typeof(DistSSHQueue._job_row), Base.Dict{String, Any}, String}` | 197.1 | 198.1 |
| `Tuple{typeof(DistSSHQueue._row_dt), String, String}` | 83.7 | 83.8 |
| `Tuple{Core.TypeEgal{Base.Dict{String, Any}}, Base.Generator{Base.Dict{String, Any}, DistSS...` | 28.7 | 28.8 |
| `Tuple{typeof(Distributed.flush_gc_msgs)}` | 23.0 | 23.7 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:id, :kind, :script, :hosts, :state, :queued_at, :s...` | 21.7 | 21.8 |
| `Tuple{Core.TypeEgal{Base.Dict{String, Any}}, Pair{String, String}, Pair{String, String}, P...` | 15.1 | 15.3 |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 14.8 | 14.9 |
| `Tuple{typeof(Base.iterate), Base.Dict{String, Any}}` | 12.3 | 12.4 |

