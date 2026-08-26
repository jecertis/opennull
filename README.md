# opennull

> [!WARNING]
> **Beta software.** This project works end-to-end but is under heavy
> development: expect breaking changes to the CLI, config format, and
> behavior between releases, rough edges, and incomplete platform testing.
> Use it to experiment — not in production.

A minimal agentic coding CLI in Zig: give it a prompt, it reads and edits
real files inside a sandboxed workspace, routed through whichever LLM
provider your config selects.

Built test-first (every module has BDD-style specs in `test/`); requires
**Zig 0.16.0** if building from source.

## Install

**One line** (macOS / Linux; installs to `~/.local/bin`):

```sh
curl -fsSL https://raw.githubusercontent.com/jecertis/opennull/main/install.sh | sh
```

Or grab a tarball directly from [Releases](https://github.com/jecertis/opennull/releases/latest) —
statically-linked Linux and macOS builds for x86_64 and arm64 (~0.5 MB).

Note: downloading or cloning the repo alone gives you **source code**, not a
runnable `opennull` — use the installer above, extract a release tarball onto
your `$PATH`, or build it yourself below.

## Quick start

**Zero config**: export any one provider key (free tiers work) and go:

```sh
export ANTHROPIC_API_KEY=sk-ant-...   # or GROQ_API_KEY / GEMINI_API_KEY /
opennull chat                         # OPENROUTER_API_KEY (all have free tiers)
```

No keys at all? Start [Ollama](https://ollama.com) (`ollama serve` + `ollama pull llama3.2`) —
the zero-config default chain is Anthropic → Groq → Gemini → OpenRouter → local Ollama,
first available wins.

**Or customize** with `config.toml` (copy from `examples/config.toml`; providers,
routes/hints, pricing, sandbox allow-list):

```sh
cp examples/config.toml config.toml   # then edit providers/routes
```

`opennull` looks for `config.toml` and `.env` in the current directory — the
directory you start it in is the sandboxed workspace root.

## Build & test

Requires **Zig 0.16.0**.

```sh
zig build            # binary at zig-out/bin/opennull
zig build test       # full suite: 22 test binaries, offline, no network needed
zig build -Doptimize=ReleaseSafe -Dstrip=true   # release binary
```

## Configuration

See `examples/config.toml` for a complete annotated sample.

| Section | Purpose |
|---|---|
| `[general]` | `default_hint` names which route to use; optional `system_prompt` replaces the built-in agent charter |
| `[providers.<name>]` | `kind` (`anthropic` or `openai_compat`), `base_url`, and `api_key_env` naming an env var — keys never live in the file |
| `[[routes]]` | maps a hint to a provider + model; unknown hints fail loudly |
| `[pricing.<model>]` | `$`/Mtok `input`/`output` rates and/or per-request `flat`, used for cost reporting |
| `[sandbox]` | `allow` list of extra readable paths outside the workspace root |

API keys resolve from the process environment first, `.env` second.

## Commands

- **`run "<prompt>"`** — one full agent turn: tool calls execute live, text
  streams in as it is generated, then the process prints a token/cost line
  and exits.
- **`chat`** — same machinery with persistent history across turns.
  Blank lines are ignored; `/exit` or `/quit` or Ctrl-D ends the session.

Both stream responses live over SSE (Anthropic and OpenAI-compatible
endpoints); if a provider/transport cannot stream, they fall back to
buffered replies automatically.

## Footprint

Deliberately tiny. The entire project is **~6,200 lines of Zig** with
**zero third-party dependencies** — `build.zig.zon` declares none, every
import in the codebase is either Zig's stdlib or a local module, there is
no C code, and the Linux builds are fully static.

| What | Size |
|---|---|
| Binary | 1.0–1.3 MB per platform |
| Release download | ~0.5 MB tarball |
| Whole source tree (incl. tests) | 61 KB compressed |

For scale: mainstream agent CLIs ship an order of magnitude larger before
you count their language runtimes — Claude Code's npm package alone is
tens of MB unpacked (~30 MB in earlier releases, ~70 MB with current
vendored binaries), and Python-based agents have historically pulled in
hundreds of MB of dependencies.

## Architecture

Closed-set tagged unions over dynamic dispatch wherever the set is known at
compile time (tools, provider kinds) — exhaustiveness checking, no vtables.

```
src/
  security/sandbox.zig    workspace-scoped path policy (+ config allow-list)
  config/                 .env parser, TOML subset parser, typed Config loader
  provider/               neutral chat types, anthropic + openai_compat,
                          AnyProvider union, real HTTP transport
  router/                 hint -> route selection -> provider construction
  tools/                  Tool interface, file_read/file_write/file_edit, registry
  agent/                  turn loop, session (multi-turn + usage totals)
  cli/                    bootstrap (startup seam), display helpers, run, chat
test/                     one BDD spec file per module, wired in build.zig
```

Testing philosophy: pure logic is fully unit-tested against injected fake
transports; the few real-I/O seams (`bootstrap`, command `execute`s, HTTP
`send`) are deliberately untested and exercised by smoke runs instead.

## Status: beta — a lot of plumbing still to do

This is an early, single-maintainer project. What that means concretely:

- **Breaking changes are expected.** CLI flags, `config.toml` keys, and
  tool behavior may change without notice between versions.
- **Platform testing is thin.** Only the macOS Intel binary is executed
  end-to-end before each release; the arm64-macos and Linux builds are
  cross-compiled and verified by architecture but not run.
- **No CI yet** — releases are built by hand from a dev machine.
- **Free-tier model IDs drift.** The zero-config defaults (`llama-3.1-8b-instant`,
  `:free` variants) track current stable names but providers rotate them;
  override via `config.toml` when they do.
- **Security posture is basic**: the sandbox resolves paths lexically (no
  symlink-following protection), tools are file-only, and there is no
  shell-execution tooling — which is also why it can't wreck much.
- Known rough edges: streamed tool calls dispatch only after their
  arguments finish arriving; REPL exits if one input line exceeds 16 KiB.

Contributions and bug reports welcome — the whole codebase is BDD-tested
and small enough to read in an afternoon.

## Limitations

- Tool calls are dispatched only after their streamed arguments finish
  arriving (per-turn), not mid-stream.
- Tools are file-only (no shell execution).
- The TOML reader covers the subset used by configs (tables, arrays of
  tables, inline arrays of strings/numbers/bools).
- Symlink traversal is resolved lexically, not by the filesystem.

## License

MIT — see [LICENSE](LICENSE).
