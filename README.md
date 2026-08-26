<div align="center">

# ✦ opennull ✦

### Your terminal just grew an extra pair of hands.

**A featherweight agentic coding companion in pure Zig.**
Reads your code. Edits your files. Streams its thoughts. All in about one megabyte, no runtime attached.

[![Release](https://img.shields.io/github/v/release/jecertis/opennull?style=flat-square&color=brightgreen)](https://github.com/jecertis/opennull/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.16.0-orange?style=flat-square)](https://ziglang.org)
[![Dependencies](https://img.shields.io/badge/dependencies-zero-8A2BE2?style=flat-square)](#footprint)

**Install · Configure nothing · Ship**

</div>

---

> [!WARNING]
> **Beta software, beautifully unfinished.** It works end-to-end today, but
> expect breaking changes between releases, rough edges, and thin platform
> testing while the plumbing catches up with the ambition. Experiment boldly;
> deploy cautiously.

---

## Why you'll love it

Picture this: you type a sentence into your terminal, and *something actually happens*. Files get read. Code gets rewritten. Answers stream in live while they're still being written. No Electron window. No `node_modules` the size of a small moon. No YAML archaeology.

opennull is an **agentic coding CLI** that treats your terminal like first class real estate:

- 🪶 **Absurdly light** — a single ~1 MB static binary. Yes, really. [We measured.](#footprint)
- ⚡ **Live streaming** — replies appear token-by-token as the model thinks, not after an awkward silence.
- 🔌 **Bring any provider** — Anthropic, Groq, Gemini, OpenRouter, or a local Ollama. First key wins, free tiers welcome.
- 🎁 **Zero-config by default** — export one environment variable and you're running. Config file strictly optional.
- 🛡️ **Sandboxed by design** — file tools operate inside your workspace unless you explicitly allow more.
- 💸 **Knows what it costs** — every turn reports tokens straight from the wire, and dollars too once you give it a pricing table.
- 🧪 **Test-first to its bones** — every module carries BDD-style specs; 22 offline test binaries, zero network required.

## Install — one line, thirty seconds

```sh
curl -fsSL https://raw.githubusercontent.com/jecertis/opennull/main/install.sh | sh
```

That's it. The installer detects your platform, fetches the perfect binary from
[Releases](https://github.com/jecertis/opennull/releases/latest), tucks it into
`~/.local/bin`, and introduces itself.

Prefer to grab a tarball by hand? They're sitting in Releases, ~0.5 MB each:
fully static Linux builds (x86_64 & arm64) and single-file macOS builds
(Intel & Apple Silicon).

> Downloading or cloning this repo gives you **source code**, not magic — use
> the installer, drop a release tarball onto your `$PATH`, or build it yourself
> below.

## Zero to agent in two lines

```sh
export GROQ_API_KEY=gsk_...    # free tier! or ANTHROPIC_API_KEY, GEMINI_API_KEY,
opennull                        # OPENROUTER_API_KEY — or skip keys entirely:
```

No keys at all? Run [Ollama](https://ollama.com) locally (`ollama serve`,
`ollama pull llama3.2`) and opennull finds it all by itself. The built-in
fallback chain reads like a menu:

**Anthropic → Groq → Gemini → OpenRouter → local Ollama** — first available wins.

Want full control instead? Copy [`examples/config.toml`](examples/config.toml),
sculpt your own providers, routes, hints, pricing table, and sandbox allow-list.

`opennull` works out of whatever directory you launch it in — that directory
*is* the sandboxed workspace.

## Commands

| Command | What it does |
|---|---|
| `opennull` | Opens the interactive chat REPL — the default experience. |
| `opennull run "<prompt>"` | One glorious agent turn — tools fire live, text streams in, then a token/cost receipt prints and it exits like a professional. |
| `opennull chat` | Same as bare `opennull` — the same machinery, multi-turn. History persists; blank lines ignored; `/exit`, `/quit`, or Ctrl-D when you're done. |

Both stream over SSE for every supported provider — and if a transport can't
stream, they quietly fall back without making a scene.

## Footprint

Deliberately, almost offensively tiny. The entire project is **~6,200 lines of
Zig** with **zero third-party dependencies** — `build.zig.zon` declares none,
every import is stdlib-or-local, there is no C code, and the Linux builds are
fully static.

| What | Size |
|---|---|
| Binary | **1.0–1.3 MB** per platform |
| Release download | **~0.5 MB** tarball |
| Entire source tree, tests included | **61 KB** compressed |

For scale: mainstream agent CLIs ship an order of magnitude larger before you
count their language runtimes — Claude Code's npm package alone is tens of MB
unpacked (~30 MB in earlier releases, ~70 MB with current vendored binaries),
and Python-based agents have historically dragged in hundreds of MB of
dependencies. Your disk drive will barely notice us.

## Configuration (entirely optional, endlessly tweakable)

See [`examples/config.toml`](examples/config.toml) for the full annotated tour.

| Section | Superpower |
|---|---|
| `[general]` | `default_hint` picks the route; `system_prompt` replaces the built-in agent charter |
| `[providers.<name>]` | `kind` (`anthropic` / `openai_compat`), `base_url`, `api_key_env` — keys live in your env, never in files |
| `[[routes]]` | Map hint names to provider + model combos; unknown hints fail loudly, never silently misroute |
| `[pricing.<model>]` | $/Mtok rates (+ per-request flat fees) powering those satisfying cost receipts |
| `[sandbox]` | `allow` list of extra readable paths beyond the workspace |

API keys resolve from the process environment first, `.env` second. Secrets
never touch the repo.

## Build & test

Requires **Zig 0.16.0**.

```sh
zig build            # binary at zig-out/bin/opennull
zig build test       # 22 offline test binaries, 136 specs, zero network needed
zig build -Doptimize=ReleaseSafe -Dstrip=true   # the release-grade binary
```

## Architecture

Closed-set tagged unions wherever the world is known at compile time (tools,
provider kinds) — exhaustive checking, no vtable tax, smaller binaries.

```
src/
  security/sandbox.zig    workspace-scoped path policy (+ config allow-list)
  config/                 .env parser, TOML subset parser, typed Config loader
  provider/               neutral chat types, anthropic + openai_compat,
                          AnyProvider union, SSE decoder, real HTTP transport
  router/                 hint -> route selection -> provider construction
  tools/                  Tool interface, file_read/file_write/file_edit, registry
  agent/                  turn loop, session (multi-turn + usage totals)
  cli/                    bootstrap (startup seam), display helpers, run, chat
test/                     one BDD spec file per module, wired in build.zig
```

Pure logic is unit-tested against injected fake transports; the few real-I/O
seams (startup, command execution, HTTP) are exercised by smoke runs against
live mock servers.

## Status: beta — the adventure has begun

Single-maintainer project, moving fast. Concretely:

- **Breaking changes will happen** — CLI flags, config keys, and behavior may
  shift between versions without ceremony.
- **Platform testing is thin** — only the macOS Intel binary runs end-to-end
  before each release; arm64-macos and Linux builds are cross-compiled and
  architecture-verified but not executed.
- **No CI yet** — releases are hand-built with love from a dev machine.
- **Free-tier model IDs drift** — the zero-config defaults track current stable
  names; override via `config.toml` when providers shuffle them.
- **Security posture is basic** — lexical path resolution (no symlink armor),
  file-only tools, no shell execution. Which also means limited blast radius.

Contributions and bug reports wildly welcome — the codebase is small enough to
read in an afternoon and tested enough to change fearlessly.

## Limitations

- Streamed tool calls dispatch once their arguments finish arriving, per turn.
- One input line over 16 KiB ends the REPL session.
- Symlink resolution is lexical, not filesystem-real.
- The TOML reader covers the config subset: tables, arrays of tables, inline
  arrays of strings/numbers/bools.

## License

MIT — see [LICENSE](LICENSE). Pre-release notice included; production
workloads should wait for the grown-up version.
