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

:- use_module(library(main)).
:- use_module(library(apply)).

:- initialization(main,main).

main(Argv) :-
    argv_options(Argv, Files, Options),
    maplist(set_option, Options),
    load_mcp_file('../examples/prolog_help'),
    mcp_run(Files, Options).

set_option(target(Boolean)) =>
    set_prolog_flag(mcp_target, Boolean).
set_option(devel(Boolean)) =>
    set_prolog_flag(mcp_devel, Boolean).
set_option(_) =>
    true.

%!  load_mcp_file(+RelativeFile) is det.
%
%   Load a file from the MCP pack relative  to the current file. We must
%   load the server dynamically to  only   include  those parts that are
%   necessary.

load_mcp_file(Relative) :-
    source_file(load_mcp_file(_), ThisFile),
    absolute_file_name(Relative, File,
                       [ relative_to(ThisFile),
                         file_type(source),
                         access(read)
                       ]),
    use_module(File).

mcp_run([], _Options) =>
    mcp_stdio_run.
mcp_run(_Files, _Options) =>
    argv_usage(debug),
    halt(1).

opt_type(target, target, boolean(true)).
opt_type(devel,  devel,  boolean).

opt_help(help(usage),
         " [option ...]").
opt_help(help(header),
         md("# SWI-Prolog MCP server with stdio transport

             This app starts the SWI-Prolog MCP (Model Context Protocol)
             server with _stdio_ (JSON-RPC) transport.  It provides:

               - Access to the Prolog manual and introspection
               - Search and read the SWI-Prolog C and Prolog sources
               - Search the GIT history of the sources
               - Run Prolog interactively

             __Make sure your agent runs in a sandbox as running Prolog
             interactively is a SECURITY risk.__
            ")).
opt_help(target,
         "`--no-target` disables interactive Prolog").
opt_help(devel,
         "Include dev_reload tools that allows the LLM to run make/0 in this server").
