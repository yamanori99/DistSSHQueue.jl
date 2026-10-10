# DistSSHQueue.jl

[English](README.md) · [日本語](README.ja.md)

<!-- markdownlint-disable MD013 -->
[![Test](https://img.shields.io/github/actions/workflow/status/yamanori99/DistSSHQueue.jl/CI.yml?branch=main&style=flat-square&logo=githubactions&logoColor=white&label=Test)](https://github.com/yamanori99/DistSSHQueue.jl/actions/workflows/CI.yml)
[![Codecov](https://img.shields.io/codecov/c/github/yamanori99/DistSSHQueue.jl?style=flat-square&logo=codecov&logoColor=white)](https://codecov.io/gh/yamanori99/DistSSHQueue.jl)
[![docs-stable](https://img.shields.io/badge/docs-stable-blue?style=flat-square&logo=gitbook&logoColor=white)](https://yamanori99.github.io/DistSSHQueue.jl/stable/)
[![docs-dev](https://img.shields.io/badge/docs-dev-blue?style=flat-square&logo=gitbook&logoColor=white)](https://yamanori99.github.io/DistSSHQueue.jl/dev/)
[![Julia 1.13+](https://img.shields.io/badge/Julia-1.13+-9558B2?style=flat-square&logo=julia&logoColor=white)](https://yamanori99.github.io/DistSSHKit.jl/stable/requirements/)
[![code style: runic](https://img.shields.io/badge/code_style-%E1%9A%B1%E1%9A%A2%E1%9A%BE%E1%9B%81%E1%9A%B2-black)](https://github.com/fredrikekre/Runic.jl)
[![License](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](LICENSE)
<!-- markdownlint-enable MD013 -->

DistSSHQueue は、つけたままのマシンにジョブを置いて、1件ずつ走らせる。
ジョブの投入、状態の確認、成果物の取得、取り消しができる。
長い説明は
[DistSSHKit のマニュアル](https://yamanori99.github.io/DistSSHKit.jl/stable/)
にある。
対応は **macOS、Linux、WSL2 Ubuntu** (ネイティブ Windows は対象外)。

小さな研究室や個人でも、常時起動のマシンを 1 台置き、SSH接続したマシンとまとめて小さな計算ノードとして使うことが出来る。
Julia **1.13+**。

## インストール

Julia REPL で `]` を押して Pkg モードに入り、次を実行する。

```julia
pkg> add DistSSHQueue
```

同じことを `Pkg` API で書くと次のとおり。

```julia
julia> import Pkg; Pkg.add("DistSSHQueue")
```

キューホストには **`ssh`**、**`rsync`**、および (git デプロイを使うときだけ) **`git`** も必要。
`pkg> add` では入らない。詳細な利用条件については以下:
[Requirements](https://yamanori99.github.io/DistSSHKit.jl/stable/requirements/)。

パッケージの詳細は **[ドキュメント](https://yamanori99.github.io/DistSSHQueue.jl/stable/)** を参照。

公式ドキュメント本体は英語である。

## 使用方法

### 基本用語

- **キューホスト** — `~/.distsshqueue` を持ち、`serve` を動かす常時起動の
  **macOS または Linux** (VM でよい)。スリープするマシンはこれではない。
  WSL2 はクライアントまたはワーカーであり、この役ではない。
- **クライアント** — 投入・一覧・監視・取消・成果物の取得をする開発マシン。台数に上限はない。
  仕事を配るプロセスになってはならない。
- **serve** — つけたままのマシン上の FIFO プロセス。
  (`execute!(…; detached=true)`) でジョブを始める。止めても、既に走っている
  ジョブは取り消されない。
- **ワーカー** — スクリプトが実際に走る先。ホストトークン:
  つけたままのマシン上は `parent[:N]`、SSH 先は `child:NAME[:N]`。

```text
  clients = dev machines (no cap)         one queue host (always on)
  -------------------------------         --------------------------
  yours / a colleague's / ...             FIFO     one job at a time
       |                                  table    ~/.distsshqueue
       |  julia -m DistSSHQueue           add-host / remove-host
       |    qhost:NAME                    serve    now, this terminal
       |    submit | status | list-host   enable   again after reboot
       |    watch | cancel | fetch | ...
       +--------------------------------> then go / ride / drive
                                          -> workers (host tokens)
```

`qhost:NAME` はつけたままのマシンの SSH 名である (`child:NAME` と同じ形だが、
ワーカーではなくそのマシンを指す)。そのマシンにいないときはコマンドラインに
`qhost:HOST` を付ける。`DISTSSHQUEUE_HOST` だけではそこへ SSH しない。
すでにそのマシンにログインしていれば `qhost:` を省略する (このマシンの cwd
がジョブの木。配置はこれまでどおり `parent` / `child:`)。手元の試行:
`DISTSSHQUEUE_LOCAL=1`。`--hosts` / `--julia` は `go` / `ride` / `drive` のまま。

ホストトークン、`go` / `ride` / `drive` のフラグ、リモートの準備は
[DistSSHKit のマニュアル](https://yamanori99.github.io/DistSSHKit.jl/stable/)
にある。

### submit

1つのargvに4つの入れ子がある。`submit` はつけたままのマシンにジョブを置く。
その後ろは `go` / `ride` / `drive` とその先である。同じ argv をこのマシンで
今走らせる説明は
[DistSSHKit のマニュアル](https://yamanori99.github.io/DistSSHKit.jl/stable/manual/)
にある。

```bash
julia --project=. -m DistSSHQueue  [qhost:HOST]  submit  drive  parent:4  SCRIPT.jl
#──────────── Julia ────────────┘  └─ qhost ──┘  submit  └── go / ride / drive ──┘
```

```bash
julia --project=. -m DistSSHQueue [qhost:HOST] submit drive parent:4 SCRIPT.jl
```

長い行は `submit` のあとで `\` 折り:

```bash
julia --project=. -m DistSSHQueue [qhost:HOST] submit \
    drive parent:4 child:NAME:N SCRIPT.jl
```

同じ argv を、このマシンで今走らせる:

```bash
julia -m DistSSHKit drive parent:4 SCRIPT.jl
```

`pool:N` は `submit` の隣に置く。ホストトークンではない。詳細:
[submit](https://yamanori99.github.io/DistSSHKit.jl/stable/queue/submit/)。

### ファイルの置き場

`qhost:` は SSH 名であり、保存先の接頭辞ではない。

- 待ち行列とジョブの結果は、つけたままのマシンに残る。
- `qhost:` submit はクライアントの木を
  `~/.distsshqueue/stage/<uuid>` へ送る。
- クライアントには `.distsshqueue/tickets/<uuid>` が残る。
- 成果物はスクリプトが所有する。
- つけたままのマシンの `.distsshkit/` run bundle はジョブが持つ。
- スケジュールと取得後の `.distsshqueue/` copy はこのパッケージが持つ。

stage では `.gitignore`、`.git/`、`.distsshkit/`、
`.distsshqueue/` を除外する。詳細:
[Artifacts and paths](https://yamanori99.github.io/DistSSHKit.jl/stable/queue/artifacts/)。

#### クライアント

```text
~/my-job/
  Project.toml          DistSSHQueue (CLI)
  Manifest.toml
  SCRIPT.jl             qhost: submit で rsync
  .distsshqueue/tickets/<uuid>  qhost: submit のたび (残す)
  .distsshqueue/<kind>/<stem>_<id8>/  fetch のあと
    .distsshqueue-fetch-id
    ...                              primary artifact copy
    .distsshkit/logs/...
    .distsshkit/collect/...
```

#### つけたままのマシン

`~/.distsshqueue` は待ち行列を持つ。`qhost:` のジョブツリーは
`stage/<uuid>/`。`parent` はこの stage をこのマシン上で使う。共有
config では `DISTRIBUTED_REMOTE_PROJECT_ROOT` を設定しない。`child:`
へのコピーは `~/stage/<uuid>` のまま分かれる。

```text
~/.distsshqueue/
  config.toml
  jobs.toml             全行 (prune しない)
  jobs.toml.log
  jobs.toml.pid         serve 中
  jobs.toml.stopped     stop 後、serve まで
  env/                  qhost: 既定 --project=。enable はあれば使う
    Project.toml
    Manifest.toml
  stage/<uuid>/         qhost: submit のたび (ジョブ id)
    Project.toml        計算の依存
    SCRIPT.jl
    .distsshkit/runs/<kind>/<run>/  run.toml, kit.pid, kit.result
    .distsshkit/<kind>/SCRIPT_<UTC>_<id>/  result_path (ジョブかスクリプトが決める)
    .distsshkit/setup/*.log         setup logs
```

`enable` (任意。この端末の `serve` だけなら不要):

- **macOS** — `~/Library/LaunchAgents/org.distsshqueue.serve.plist`
- **Linux / WSL2** — `~/.config/systemd/user/distsshqueue.serve.service`

ユーザ unit (root 不要)。中身は同じ
`julia --project=<queue-env> -m DistSSHQueue serve`。

#### ワーカー

`parent` はつけたままのマシン自身である。stage
(`~/.distsshqueue/stage/<uuid>/`) をその場で使う。待ち行列は隣に残る。

`child:` には待ち行列は無い。ジョブツリーはつけたままのマシンから
rsync し、実行前にそこで instantiate する。

- `~/.distsshqueue` も `jobs.toml` も無い。
- `qhost:` ならコピー先は `~/stage/<uuid>` でジョブごとに違う。共有
  `config.toml` に `DISTRIBUTED_REMOTE_PROJECT_ROOT` は書かない。
- 成果物はここに残らない。つけたままのマシンへ収集する。既定 leaf は
  上の `.distsshkit/<kind>/` だが、custom な `output_dir` はその先へ
  落ち、そのパスは `result_path` として残る (fetch は
  プロジェクト外でもそこを辿る)。

```text
~/stage/<uuid>/         qhost: のあと child: へコピー (この uuid だけ)
  Project.toml
  Manifest.toml
  SCRIPT.jl
```

### 例

**クライアント** から (ジョブのディレクトリ。その env からこのパッケージが load できること):

```bash
julia --project=. -m DistSSHQueue qhost:HOST list-host
julia --project=. -m DistSSHQueue qhost:HOST size
julia --project=. -m DistSSHQueue qhost:HOST plan SCRIPT.jl
julia --project=. -m DistSSHQueue qhost:HOST pool
julia --project=. -m DistSSHQueue qhost:HOST submit go child:host1:4 SCRIPT.jl
julia --project=. -m DistSSHQueue qhost:HOST status
julia --project=. -m DistSSHQueue qhost:HOST watch
julia --project=. -m DistSSHQueue qhost:HOST cancel <id>
julia --project=. -m DistSSHQueue qhost:HOST fetch <id>  # 8文字プレフィックスでもフルUUIDでも可
julia --project=. -m DistSSHQueue qhost:HOST fetch .distsshqueue/tickets/<uuid>
```

`submit` は、`serve` が無ければつけたままのマシン上で起動する。`serve` が
ジョブ木をそこで `Pkg.instantiate` し、`child:` には
`setup!` を走らせる (stage で `setup` を手で打たない)。
`:check` は `child:` で常に走る。`qhost:` の stage は `.git/`
を送らないが、無いときは fail ではなく警告にする。
ジョブ id は
stdout 1 行。stderr に `Queued  N` (`DISTSSHKIT_QUIET` で隠す)。
`fetch` は終わった結果をこのジョブ木の
`.distsshqueue/<kind>/<stem>_<id8>/` へ戻す。

打つ順 (マシンの準備 → submit / fetch → teardown):
[Walkthrough](https://yamanori99.github.io/DistSSHKit.jl/stable/tutorial/queue-walkthrough/)。

**つけたままのマシン** で一度だけ。`setup` は `config.toml` を書く (`env/` は作らない)。
既定の Julia 環境で `julia -m DistSSHQueue`。チェックアウトなら `--project=.`。

```bash
julia -m DistSSHQueue setup
julia -m DistSSHQueue add-host parent child:host1
julia -m DistSSHQueue serve
```

`qhost:` の既定は `--project=~/.distsshqueue/env` (リモート既定環境は
`--queue-env @`)。`enable` はその dir があれば使う。`setup` / `serve` /
`enable` / `disable` / `add-host` / `remove-host` は `qhost:` を
受け付けない。コマンド参照:
[How it runs](https://yamanori99.github.io/DistSSHKit.jl/stable/queue/)。

## ドキュメント

- Home:
  [Home](https://yamanori99.github.io/DistSSHQueue.jl/stable/)
- マニュアル:
  [DistSSHKit](https://yamanori99.github.io/DistSSHKit.jl/stable/manual/)
- API: [API](https://yamanori99.github.io/DistSSHQueue.jl/stable/api/)
- News: [NEWS.md](NEWS.md)

## 貢献

バグ報告・機能要望は [Issues](https://github.com/yamanori99/DistSSHQueue.jl/issues)。
貢献の仕方は [CONTRIBUTING.md](CONTRIBUTING.md) を参照。

## ライセンス

ソースコードは [MIT](LICENSE)。

<!-- markdownlint-disable MD033 -->
<p align="center">
  <picture>
    <source
      media="(prefers-color-scheme: dark)"
      srcset="https://raw.githubusercontent.com/yamanori99/DistSSHQueue.jl/main/docs/src/assets/logo/logo-dark-static.svg">
    <source
      media="(prefers-color-scheme: light)"
      srcset="https://raw.githubusercontent.com/yamanori99/DistSSHQueue.jl/main/docs/src/assets/logo/logo-static.svg">
    <img
      src="https://raw.githubusercontent.com/yamanori99/DistSSHQueue.jl/main/docs/src/assets/logo/logo-static.png"
      width="210"
      alt="DistSSHQueue.jl logo"/>
  </picture>
</p>
<!-- markdownlint-enable MD033 -->
