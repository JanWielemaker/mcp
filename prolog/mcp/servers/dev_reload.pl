/*  Author:        Jan Wielemaker
    E-mail:        jan@swi-prolog.org
    WWW:           http://www.swi-prolog.org
    Copyright (c)  2026, SWI-Prolog Solutions b.v.
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions
    are met:

    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in
       the documentation and/or other materials provided with the
       distribution.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
    FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
    COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
    BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
    LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
    ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
*/

:- module(mcp_server_dev_reload, []).
:- use_module(library(mcp/server), [mcp_notify/2]).
:- use_module(library(mcp/messages), [run_collect_messages/4]).
:- use_module(library(make), [make/0]).
:- use_module(library(yall)).
:- use_module(library(apply), [maplist/3]).
:- use_module(library(lists), [append/3]).

/** <module> Self-reload tool for the MCP server itself

This module is intentionally separate from the other MCP server
modules so it can be loaded only in development setups (it grants
the LLM the power to reload arbitrary Prolog source running in the
MCP server's own process, which is fine for a developer's loop but
should never be present in a published configuration).

Tool registered:

  - mcp_reload_self    run make/0 in the MCP server process; pick up
                       edits to any of the proxy / framework modules
                       without restarting the MCP server
*/

:- mcp_tool(
       mcp_reload_self,
       "Run make/0 inside the MCP server process to pick up source \c
        edits to the proxy / framework modules without restarting \c
        the MCP server.  Returns the textual output of make (the \c
        'Loaded …', warning and error messages).\n\n\c
        After the reload, the server sends \c
        notifications/tools/list_changed so the Claude Code client \c
        re-fetches tools/list; new mcp_tool/3 declarations therefore \c
        become visible without /mcp reconnect.\n\n\c
        Caveat: if a previous bad reload left runtime state \c
        inconsistent, make/0 does not unwind it.  Symptom: \c
        subsequent calls fail with 'Internal error' even though \c
        direct invocation of the target predicate works.  Fix: /mcp \c
        reconnect.",
       #{ type: object, properties: #{} }).

mcp_reload_self(_Args, Text) :-
    run_collect_messages(make, [_]>>true, Result, Messages),
    maplist(render_message, Messages, Rendered),
    %  Tell the client to re-fetch tools/list -- new mcp_tool/3
    %  declarations from the reloaded source are otherwise invisible
    %  to it (the client caches the list at initialize time).
    %  Requires tools.listChanged:true in the capabilities, which
    %  library(mcp/lifecycle) declares.
    catch(mcp_notify('notifications/tools/list_changed', #{}),
          error(_,_), true),
    reload_text(Result, Rendered, Text).

render_message(message(_Term, _Kind, Lines), S) :-
    with_output_to(string(S),
                   print_message_lines(current_output, '', Lines)).

reload_text(true, [], "make/0: nothing to reload.") :- !.
reload_text(true, Rendered, Text) :- !,
    atomic_list_concat(Rendered, Text).
reload_text(exception(E), Rendered, Text) :- !,
    message_to_string(E, EMsg),
    format(string(Tail), "make/0 raised: ~w~n", [EMsg]),
    append(Rendered, [Tail], All),
    atomic_list_concat(All, Text).
reload_text(false, Rendered, Text) :-
    append(Rendered, ["make/0 failed.\n"], All),
    atomic_list_concat(All, Text).
