# Precompile-time component fingerprint (schema 1).

const _QUEUE_SRC_FILES = (
    "DistSSHQueue.jl",
    "job.jl",
    "env_verify.jl",
    "store.jl",
    "paths.jl",
    "config.jl",
    "messages/display.jl",
    "queue.jl",
    "client/qhost.jl",
    "client/submit.jl",
    "client/stage.jl",
    "client/fetch.jl",
    "client/status.jl",
    "client/list_host.jl",
    "client/inspect.jl",
    "client/pool.jl",
    "client/edit_hosts.jl",
    "client/cancel.jl",
    "qhost/service.jl",
    "qhost/setup.jl",
    "qhost/up.jl",
    "qhost/teardown.jl",
    "qhost/serve.jl",
)

const _COMPONENT_SRC_DIGEST = DistSSHBase.src_component_digest(@__DIR__, _QUEUE_SRC_FILES)

const COMPONENT_ID = (
    schema = 1,
    name = "DistSSHQueue",
    uuid = Base.UUID("24254401-70d8-4a51-8ea4-cfab19f5bc73"),
    version = "0.10.0-DEV",
    digest = _COMPONENT_SRC_DIGEST,
)
