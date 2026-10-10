using Documenter
using DistSSHQueue
using Base64

DocMeta.setdocmeta!(DistSSHQueue, :DocTestSetup, :(using DistSSHQueue); recursive = true)

const FAVICON_PNG_B64 = base64encode(read(joinpath(@__DIR__, "src", "assets", "favicon.png")))
const FAVICON_DARK_PNG_B64 = base64encode(read(joinpath(@__DIR__, "src", "assets", "favicon-dark.png")))

makedocs(;
    modules = [DistSSHQueue],
    authors = "Takanori Yamamoto, Honoka Ampuku, and contributors",
    sitename = "DistSSHQueue.jl",
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://yamanori99.github.io/DistSSHQueue.jl",
        edit_link = "main",
        assets = [
            "assets/custom.css",
            RawHTMLHeadContent(
                """<link id="docs-favicon" rel="icon" type="image/png" sizes="32x32" href="data:image/png;base64,$(FAVICON_PNG_B64)" data-light="data:image/png;base64,$(FAVICON_PNG_B64)" data-dark="data:image/png;base64,$(FAVICON_DARK_PNG_B64)"/>""",
            ),
            "assets/favicon-theme.js",
        ],
    ),
    pages = [
        "Home" => "index.md",
        "API" => "api.md",
    ],
    checkdocs = :none,
)

function rewrite_favicon_types!(build)
    rx_svg = r"""<link href="([^"]*favicon\.svg)" rel="icon" type="image/x-icon" type="image/svg\+xml"/>"""
    rx_png = r"""<link href="([^"]*favicon\.png)" rel="icon" type="image/x-icon" type="image/png" sizes="32x32"/>"""
    n = 0
    for (root, _, files) in walkdir(build)
        for f in files
            endswith(f, ".html") || continue
            path = joinpath(root, f)
            html = read(path, String)
            html2 = replace(
                html,
                rx_svg => s"""<link href="\1" rel="icon" type="image/svg+xml"/>""",
            )
            html2 = replace(
                html2,
                rx_png => s"""<link href="\1" rel="icon" type="image/png" sizes="32x32"/>""",
            )
            if html2 != html
                write(path, html2)
                n += 1
            end
        end
    end
    return println("rewrote favicon type on $n HTML pages")
end

rewrite_favicon_types!(joinpath(@__DIR__, "build"))

deploydocs(;
    repo = "github.com/yamanori99/DistSSHQueue.jl.git",
    devbranch = "main",
    push_preview = true,
    versions = ["stable" => "v^", "v#.#", "dev" => "dev"],
)
