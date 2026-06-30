/*  Prolog-introspection MCP server.

    Exposes library(mcp/servers/prolog_help) over stdio.  Useful as
    an MCP server attached to an LLM coding assistant working on
    Prolog code.

    Run as:

        swipl examples/prolog_help.pl
*/

:- module(prolog_help_server,
          [ mcp_stdio_run/0
          ]).
:- use_module(library(mcp/server)).
:- use_module(library(mcp/stdio)).
:- use_module(library(mcp/servers/prolog_help)).
:- use_module(library(mcp/servers/swipl_kernel)).
:- if(\+ current_prolog_flag(mcp_target, false)).
:- use_module(library(mcp/servers/target_toplevel)).
:- endif.
:- if(current_prolog_flag(mcp_devel, true)).
:- use_module(library(mcp/servers/dev_reload)).
:- endif.
:- use_module(library(mcp/servers/source)).
:- use_module(library(mcp/servers/git)).

:- mcp_server_info(#{name:"prolog-help", version:"0.1.0"}).

:- initialization(mcp_stdio_run, main).
