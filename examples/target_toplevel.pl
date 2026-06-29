/*  MCP server hosting only the toplevel-driver tools.

    Spawns a real swipl toplevel as a "target" and exposes
    target_start / target_send / target_input / target_stop.

    Run as:

        swipl examples/target_toplevel.pl
*/

:- module(target_toplevel_server, []).
:- use_module(library(mcp/server)).
:- use_module(library(mcp/stdio)).
:- use_module(library(mcp/servers/target_toplevel)).

:- mcp_server_info(#{name:"prolog-toplevel-target", version:"0.1.0"}).

:- initialization(mcp_stdio_run, main).
