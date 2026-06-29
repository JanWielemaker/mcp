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

:- module(swipl_help_public, []).
:- use_module(library(mcp/server)).
:- use_module(library(mcp/http)).
:- use_module(library(mcp/servers/prolog_help)).
:- use_module(library(mcp/servers/swipl_kernel)).
:- use_module(library(mcp/servers/source)).
:- use_module(library(mcp/servers/git)).
:- use_module(library(http/http_unix_daemon)).

:- mcp_server_info(#{name:"swipl-help", version:"0.1.0"}).

/** <module> Public MCP help server for www.swi-prolog.org

Hosts the *read-only* MCP introspection suite -- prolog_help (manual,
xref, pldoc), swipl_kernel (C-source grep), source (file listing,
reading, grep over configured roots) and git (log/blame/show/diff/
grep on roots that are git work-trees).  Deliberately omits
target_toplevel (spawns child swipl processes) and dev_reload (calls
make/0 in the server process) -- both are appropriate only in a
trusted developer loop, never in a public-facing deployment.

Run via library(http/http_unix_daemon):

    swipl examples/swipl_help_public.pl \
        --port=8080 --ip=0.0.0.0

See the docker/ subdirectory for the production-deployment recipe.
*/

:- initialization(http_daemon, main).
