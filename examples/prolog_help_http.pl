/*  Part of SWI-Prolog

    Author:        Jan Wielemaker
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

:- module(prolog_help_http_server, []).
:- use_module(library(mcp/server)).
:- use_module(library(mcp/http)).
:- use_module(library(mcp/servers/prolog_help)).
:- use_module(library(mcp/servers/swipl_kernel)).
:- use_module(library(mcp/servers/target_toplevel)).
:- use_module(library(mcp/servers/dev_reload)).
:- use_module(library(mcp/servers/source)).
:- use_module(library(mcp/servers/git)).
:- use_module(library(http/http_unix_daemon)).

:- mcp_server_info(#{name:"prolog-help-http", version:"0.1.0"}).

/** <module> Run our MCP server with HTTP transport

MCP server hosting the prolog_help /  swipl_kernel / target / dev_reload
suite over HTTP+SSE on localhost:8080.

Mirrors examples/prolog_help.pl but boots the  HTTP transport instead of
stdio.

Run as:

    swipl examples/prolog_help_http.pl [option ...]

Endpoints (use http:location/3 with alias `mcp` to modify)

    - POST /mcp/messages
    - GET  /mcp/sse

Session id is the `Mcp-Session-Id` HTTP header  (minted by the server on
the first POST that lacks it).
*/

:- initialization(http_daemon, main).
