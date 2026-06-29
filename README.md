# MCP — Model Context Protocol server framework for SWI-Prolog

This pack provides a framework for writing
[Model Context Protocol](https://modelcontextprotocol.io/) servers in
SWI-Prolog, plus a set of ready-made server modules that an LLM coding
assistant can use to introspect Prolog code, drive a real SWI toplevel
as a "target", and read source / git history from configured
directories.

The framework rides on top of `library(json_rpc_server)` and
`library(json_schema)` that ship with SWI-Prolog.  Per-tool argument
validation against the supplied JSON Schema is handled by the JSON
Schema layer.

## Status

Experimental.  Implements the **2024-11-05** revision of the MCP
specification.

Transports:

  - **stdio** — `library(mcp/stdio)`; newline-delimited JSON-RPC over
    stdin/stdout, the form used by the official `mcp` CLI and by
    Claude Code's local-server configuration.
  - **HTTP + SSE** — `library(mcp/http)`; long-lived SSE stream for
    server-initiated notifications plus POSTs for client requests.
    Sessions are keyed by the `Mcp-Session-Id` HTTP header.  Intended
    for hosting on `www.swi-prolog.org` (behind a reverse proxy
    handling TLS and auth).

## MCP capabilities

  - Tools (`tools/list`, `tools/call`,
    `notifications/tools/list_changed`)
  - Resources (`resources/list`, `resources/read`,
    `resources/templates/list`)
  - Prompts (`prompts/list`, `prompts/get`)

Progress notifications (`notifications/progress` and the
`params._meta.progressToken` intake on requests) are not implemented.
Tool calls reply with a single buffered JSON-RPC response; there is no
intra-call streaming.  On the HTTP transport the `mcp_notify/2` path
reaches only clients holding a `GET /sse` stream — the streamable-HTTP
`POST /mcp` reply is sent as `application/json`, not as an SSE event
stream, so a tool cannot interleave progress events into its own
response.

## Writing a server

A minimal _hello_ server:

```prolog
:- module(hello_server, []).
:- use_module(library(mcp/server)).
:- use_module(library(mcp/stdio)).

:- mcp_server_info(#{name:"hello", version:"0.1.0"}).

:- mcp_tool(echo,
            "Echo the input message",
            #{ properties: #{ msg: #{type: string} },
               required: [msg]
             }).

echo(#{msg: M}, M).

:- initialization(mcp_stdio_run, main).
```

Run it as `swipl hello_server.pl`.  The server speaks MCP on
stdin/stdout.

`mcp_tool/3` is the only registration primitive: a name, a one-line
description shown to the LLM, and a JSON Schema for the arguments.
The matching Prolog predicate is `Name(+Args, -Result)`, where `Args`
is the validated input dict and `Result` is either a string (auto-
wrapped as a text content item), a dict (a single content item) or a
list of content items.

## Included server modules

Each of these is `:- use_module/1`-able as
`library(mcp/servers/<name>)`.  They all register their tools through
the same multifile `tool/4` predicate, so a single server can compose
several modules and present them as one client-facing surface.

### `library(mcp/servers/prolog_help)`

SWI-Prolog introspection for an LLM coding assistant working on
Prolog code.  Tools:

| Tool                          | What it returns                                                                |
| ----------------------------- | ------------------------------------------------------------------------------ |
| `predicate_help`              | Manual entry for `Name/Arity` as plain text.                                   |
| `apropos`                     | Manual search by predicate name or summary; scored, capped.                    |
| `predicate_listing`           | Clauses of a defined predicate (decompiled or original-source).                |
| `predicate_info`              | Raw `predicate_property/2` snapshot for a predicate.                           |
| `predicate_property_summary`  | Curated, grouped view of the same — Module / Location / Kind / Modifiers.      |
| `pldoc_signature`             | PlDoc mode declarations and determinism (`is det`/`semidet`/…) + `:- meta_predicate`. |
| `file_xref`                   | Cross-reference summary of a `.pl` file (defines / exports / calls / uses).    |
| `file_check`                  | xref a file and report warnings / errors and undefined-call sites.             |
| `module_exports`              | Exports of a module with one-line summaries per export.                        |
| `file_autoload`               | Computed `:- autoload/2` (or `use_module/2`) directive block a file needs.     |
| `predicate_callers`           | Walk a source root and find every call site of a predicate.                    |
| `pack_info`                   | Metadata for an installed pack.                                                |
| `locate_source`               | Source location(s) for a predicate — Prolog clauses *and* C built-ins.         |
| `explain`                     | `library(explain)` snapshot of a term: kind, definitions, references.          |
| `manual_section`              | Body of a manual section by anchor (`sec:<id>`).                               |

Also registers a `prolog://help/{name}/{arity}` resource template so
clients that prefer resources over tools can fetch help that way.

### `library(mcp/servers/source)`

Read source from named roots.  Every tool takes a `root` name (the
`source_roots` tool lists what is configured); the relative path is
joined with the root and verified to stay inside it (no `..`
escapes).  Roots are added either by the
`mcp_source:swipl_devel_root` setting (the built-in `"swipl-devel"`
root) or by multifile `mcp_server_source:source_root/2` clauses.

| Tool             | What it returns                                                       |
| ---------------- | --------------------------------------------------------------------- |
| `source_roots`   | Configured roots with absolute paths and a `(git)` tag.               |
| `source_list`    | Files in a sub-directory of a root, optional glob, sizes.             |
| `source_read`    | A file (or a line range) with line numbers, byte-capped.              |
| `source_search`  | Recursive POSIX-ERE grep across a root.                               |

### `library(mcp/servers/git)`

Read-only git interrogation of source roots that happen to be git
work-trees.  Reuses the source-roots configuration above.  All tools
shell out to the `git` binary with `git -C <root> <args>`; the
worktree is never written to.

| Tool         | What it returns                                              |
| ------------ | ------------------------------------------------------------ |
| `git_log`    | Recent commits, optionally restricted to a path or `--since`. |
| `git_blame`  | Per-line authorship for a file range.                        |
| `git_show`   | A commit (message + diff) or a file at a commit.             |
| `git_diff`   | Diff between two refs, optional path.                        |
| `git_grep`   | Tracked-files grep, optionally at a ref or recursing submodules. |

### `library(mcp/servers/swipl_kernel)`

Specialised tools for working on the SWI-Prolog C kernel.  The kernel
root is the setting `mcp_swipl_kernel:c_source_root` (defaults to
`/home/jan/src/swipl-devel/src`; override with `set_setting/2` at
boot).

| Tool                | What it returns                                                |
| ------------------- | -------------------------------------------------------------- |
| `c_grep`            | Recursive POSIX-ERE grep restricted to `*.c` and `*.h`.        |
| `c_function_defs`   | Function definitions in a C file, including `PRED_IMPL(...)`s. |

### `library(mcp/servers/target_toplevel)`

Drive a child `swipl` process as the "target" of an LLM coding loop:
load files into it, evaluate goals against it, run the profiler /
coverage tools without contaminating the MCP server process.  The
proxy spawns the child with the small instrumentation file in
`prolog/mcp/target_toplevel/mcp_target.pl`, which wraps the toplevel
output with magic markers so the parent can demultiplex events from
plain stdout.

Targets are identified by a string name; multiple may coexist.

| Tool                | What it does                                                          |
| ------------------- | --------------------------------------------------------------------- |
| `target_start`      | Spawn a child `swipl`, optionally pre-loading files.                  |
| `target_stop`       | Terminate the named target.                                           |
| `target_status`     | List running targets.                                                 |
| `target_send`       | Send a Prolog goal (no trailing period), return output up to the next prompt. |
| `target_load`       | `make/0` in the target, or `consult(File)`.                           |
| `target_check`      | Run `library(check)` consistency checks -- `check/0` by default, or a selected subset. |
| `target_input`      | Send raw text to a target that is awaiting input.                     |
| `target_profile`    | Run `profile/1` in the target; drill into one predicate's call tree.  |
| `target_coverage`   | Run `coverage/1` in the target; drill into one file's clauses.        |

### `library(mcp/servers/dev_reload)`

Single tool, `mcp_reload_self`: run `make/0` inside the MCP server
process to pick up source edits to the framework / tool modules
without restarting the server.  Sends
`notifications/tools/list_changed` afterwards so any new
`mcp_tool/3` declarations become visible without an `/mcp`
reconnect.

Intended for the developer's edit-test loop; do not enable in a
public deployment (it gives the LLM the power to reload arbitrary
Prolog source running in the server process).

## Examples

Runnable scripts under `examples/`:

  - `hello.pl` — minimum-viable single-tool server over stdio.
  - `prolog_help.pl` — the full assistant suite (`prolog_help` +
    `swipl_kernel` + `target_toplevel` + `source` + `git` +
    `dev_reload`) over stdio.
  - `prolog_help_http.pl` — same suite over HTTP + SSE on
    `localhost:8080`.
  - `target_toplevel.pl` — just the target-driver tools, useful as
    an "agent loop" companion.

## Tests

PLUnit smoke tests live under `tests/`.  Run the full matrix with:

    make check

Test files match `tests/test_*.pl` and are picked up automatically.
The matrix is parallel-safe (`make -j N check`); each suite runs in
its own `swipl` process.

A few suites need a real source tree to query (`test_source`,
`test_git`).  The root path is taken from the Prolog flag
`mcp_test_swipl_devel_root`, which defaults to `~/src/swipl-devel`.
Override on the command line with:

    make check SWIPL_FLAGS=-Dmcp_test_swipl_devel_root=/path/to/swipl-devel

Suites whose root is absent (or not a git work-tree, for
`test_git`) skip themselves cleanly.

## License

BSD-2-Clause.
