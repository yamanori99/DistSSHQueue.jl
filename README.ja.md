# DistSSHQueue.jl

[English](README.md) · [日本語](README.ja.md)

<!-- markdownlint-disable MD013 -->
[![Test](https://img.shields.io/github/actions/workflow/status/yamanori99/DistSSHQueue.jl/CI.yml?branch=main&style=flat-square&logo=githubactions&logoColor=white&label=Test)](https://github.com/yamanori99/DistSSHQueue.jl/actions/workflows/CI.yml)
[![PkgEval](https://raw.githubusercontent.com/yamanori99/DistSSHQueue.jl/main/docs/src/assets/pkgeval.svg)](https://juliaci.github.io/NanosoldierReports/pkgeval_badges/D/DistSSHQueue.html)
[![Codecov](https://img.shields.io/codecov/c/github/yamanori99/DistSSHQueue.jl?style=flat-square&logo=codecov&logoColor=white)](https://codecov.io/gh/yamanori99/DistSSHQueue.jl)
[![docs-stable](https://img.shields.io/badge/docs-stable-blue?style=flat-square&logo=gitbook&logoColor=white)](https://yamanori99.github.io/DistSSHQueue.jl/stable/)
[![docs-dev](https://img.shields.io/badge/docs-dev-blue?style=flat-square&logo=gitbook&logoColor=white)](https://yamanori99.github.io/DistSSHQueue.jl/dev/)
[![Julia 1.12+](https://img.shields.io/badge/Julia-1.12+-9558B2?style=flat-square&logo=julia&logoColor=white)](https://yamanori99.github.io/DistSSHQueue.jl/stable/requirements/)
[![License](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](LICENSE)
<!-- markdownlint-enable MD013 -->

DistSSHQueue は、何人かで同じマシンを使い、ジョブを順番に走らせるものである。
ジョブの投入、状態の確認、成果物の取得、取り消しができる。
実行は [DistSSHKit](https://github.com/yamanori99/DistSSHKit.jl) が担う。
対応は **macOS、Linux、WSL2 Ubuntu** (ネイティブ Windows は対象外)。

小さな研究室や個人でも、常時起動のマシンを 1 台置き、SSH接続したマシンとまとめて小さな計算ノードとして使うことが出来る。
Julia **1.12+**、DistSSHKit **0.7.x**。

## インストール

Julia REPL で `]` を押して Pkg モードに入り、次を実行する。

```julia
pkg> add DistSSHQueue
```

同じことを `Pkg` API で書くと次のとおり。

```julia
julia> import Pkg; Pkg.add("DistSSHQueue")
```

DistSSHKit **0.7.x** は General から付いてくる。通常の Queue 作業で
Kit を `Pkg.develop` しない。

キューホストには **`ssh`**、**`rsync`**、および (git デプロイを使うときだけ) **`git`** も必要。
`pkg> add` では入らない。詳細な利用条件については以下:
[Requirements](https://yamanori99.github.io/DistSSHQueue.jl/stable/requirements/)。

パッケージの詳細は **[ドキュメント](https://yamanori99.github.io/DistSSHQueue.jl/stable/)** を参照。

公式ドキュメント本体は英語である。

## 使用方法

### 基本用語

- **キューホスト** — `~/.distsshqueue` を持ち、`serve` を動かす常時起動の
  **macOS または Linux** (VM でよい)。スリープするラップトップはこれではない。
  WSL2 はクライアントまたはワーカーであり、この役ではない。
- **クライアント** — 投入・一覧・監視・取消・成果物の取得をする開発マシン。台数に上限はない。
  Kit のマスターになってはならない。
- **serve** — キューホスト上の FIFO プロセス。DistSSHKit
  (`execute!(…; detached=true)`) を起動する。止めても、既に走っている
  Kit ジョブは取り消されない。
- **ワーカー** — スクリプトが実際に走る先。DistSSHKit のトークン:
  キューホスト上は `parent[:N]`、SSH 先は `child:NAME[:N]`。

```text
  clients = dev machines (no cap)         one queue host (always on)
  -------------------------------         --------------------------
  yours / a colleague's / ...             FIFO     one Kit job at a time
       |                                  table    ~/.distsshqueue
       |  julia -m DistSSHQueue           add-host / remove-host
       |    qhost:NAME                    serve    now, this terminal
       |    submit | status | list-host   enable   again after reboot
       |    watch | cancel | fetch | ...
       +--------------------------------> then DistSSHKit go/ride/drive
                                          -> workers (Kit tokens)
```

`qhost:NAME` はキューホストの SSH 名である (Kit の `child:NAME` と同じ形だが、
ワーカーではなくキューホストを指す)。既にそのマシンにログインしていれば省略する。
キューホストが 1 つのとき: `export DISTSSHQUEUE_HOST=…` して `qhost:` を省略できる
(トークンがあればそちらが勝つ)。`--hosts` / `--julia` は Kit の `go` / `ride` / `drive` のまま。

配置トークン、`go` / `ride` / `drive` のフラグ、リモートの準備は DistSSHKit の範囲である。
[kit docs](https://yamanori99.github.io/DistSSHKit.jl/stable/) を参照。

### ファイルの置き場

`qhost:` はキューホストの SSH 名であり、保存先の接頭辞ではない。表と Kit の
結果ディレクトリは **そのマシン** に残る。クライアントに
`~/.distsshqueue` は無い。`qhost:` submit はクライアントのジョブ木を
`~/.distsshqueue/stage/<id>` へ rsync する (Kit と同じ: `.gitignore`、
`.git/`、`.distsshkit/`、`.distsshqueue/`)。
クライアントには `.distsshqueue/tickets/<uuid>` が残る (submitのたびに増え、消さない)。Kit はキューホストから
worker へコピーする。`fetch` は終わった Kit leaf を戻す。

#### クライアント

```text
~/my-job/
  Project.toml          DistSSHQueue (CLI)
  Manifest.toml
  SCRIPT.jl             qhost: submit で rsync
  .distsshqueue/tickets/<uuid>  qhost: submit のたび (残す)
  .distsshqueue/go/     fetch のあと
  .distsshqueue/ride/   fetch のあと
  .distsshqueue/drive/  fetch のあと
```

#### キューホスト

`~/.distsshqueue` と **ジョブごとに一つの Kit 木** (`qhost:` なら
`stage/<id>/`、省略なら `~/org/Repo.jl`)。`--queue-env` とは別。
共有 `config.toml` に `DISTRIBUTED_REMOTE_PROJECT_ROOT` は書かない。
二本目のプロジェクトが同じ worker パスなら `submit` はエラー。

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
  stage/<id>/           qhost: submit 後のクライアント木

~/org/Repo.jl/          qhost: 省略 (cwd / DISTRIBUTED_PROJECT_ROOT)
  Project.toml          計算の依存
  SCRIPT.jl
  .distsshkit/go/
    SCRIPT_<UTC>_<id>/  result_path
      kit.pid
      kit.result
  .distsshkit/ride/
    SCRIPT_<UTC>_<id>/  同じ allocate
  .distsshkit/drive/
    SCRIPT_<UTC>_<id>/  同じ allocate。demo の output/ ではない
```

`enable` (任意。この端末の `serve` だけなら不要):

- **macOS** — `~/Library/LaunchAgents/org.distsshqueue.serve.plist`
- **Linux / WSL2** — `~/.config/systemd/user/distsshqueue.serve.service`

ユーザ unit (root 不要)。中身は同じ
`julia --project=<queue-env> -m DistSSHQueue serve`。

#### ワーカー

Queue の表は無い。Kit 既定は `~/parent/Repo.jl` (共有 `[env]` の
remote ではない)。収集先は上のキューホスト `.distsshkit/`。

```text
<remote project root>/
  Project.toml
  SCRIPT.jl
```

### 例

**クライアント** から (ジョブのディレクトリ。その env から Queue が load できること):

```bash
julia --project=. -m DistSSHQueue qhost:mini list-host
julia --project=. -m DistSSHQueue qhost:mini size
julia --project=. -m DistSSHQueue qhost:mini plan SCRIPT.jl
julia --project=. -m DistSSHQueue qhost:mini pool
julia --project=. -m DistSSHQueue qhost:mini submit go child:host1:4 SCRIPT.jl
julia --project=. -m DistSSHQueue qhost:mini status
julia --project=. -m DistSSHQueue qhost:mini watch
julia --project=. -m DistSSHQueue qhost:mini cancel <id>
julia --project=. -m DistSSHQueue qhost:mini fetch <id>  # 8文字プレフィックスでもフルUUIDでも可
julia --project=. -m DistSSHQueue qhost:mini fetch .distsshqueue/tickets/<uuid>
```

`submit` は、`serve` が無ければキューホスト上で起動する。`serve` が
ジョブ木をキューホスト上で `Pkg.instantiate` し、`child:` には Kit
`setup!` を走らせる (stage で DistSSHKit `setup` を手で打たない)。
ジョブ id は
stdout 1 行。stderr に `Queued  N` (`DISTSSHKIT_QUIET` で隠す)。
`fetch` は終わった Kit leaf をこのジョブ木へ戻す。

打つ順 (キューホスト → go / fetch → teardown):
[Walkthrough](https://yamanori99.github.io/DistSSHQueue.jl/stable/tutorial/walkthrough/)。

**キューホスト** で一度だけ。`setup` は `config.toml` を書く (`env/` は作らない)。
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
[User Guide](https://yamanori99.github.io/DistSSHQueue.jl/stable/manual/)。

## ドキュメント

- Introduction:
  [Introduction](https://yamanori99.github.io/DistSSHQueue.jl/stable/)
- First Steps:
  [First Steps](https://yamanori99.github.io/DistSSHQueue.jl/stable/requirements/)
- User Guide:
  [User Guide](https://yamanori99.github.io/DistSSHQueue.jl/stable/manual/)
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
