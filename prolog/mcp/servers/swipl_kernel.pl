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

:- module(mcp_server_swipl_kernel, []).
:- use_module(library(mcp/server)).
:- use_module(library(process), [process_create/3, process_wait/2]).
:- use_module(library(settings), [setting/4, setting/2]).
:- use_module(library(filesex), [directory_file_path/3]).
:- use_module(library(lists), [member/2, append/3]).

/** <module> MCP tools for the SWI-Prolog C kernel

Loading this module registers MCP tools for exploring the SWI-Prolog C
sources.  Useful for an LLM coding assistant working on the kernel.

Tools registered:

  - c_grep            -- regex search in `*.c` and `*.h` under the kernel tree
  - c_function_defs   -- function definitions in a C source file

The tree to search is controlled by the setting

    mcp_swipl_kernel:c_source_root

which defaults to /home/jan/src/swipl-devel/src .  Override with e.g.

    ?- set_setting(mcp_swipl_kernel:c_source_root,
                   '/path/to/swipl-devel/src').
*/

:- setting(mcp_swipl_kernel:c_source_root, atom,
           '/home/jan/src/swipl-devel/src',
           'Root of the SWI-Prolog C kernel source tree').


                /*******************************
                *           TOOLS              *
                *******************************/

:- mcp_tool(
       c_grep,
       "Recursively grep the SWI-Prolog C kernel sources (*.c and *.h) \c
        for an extended regular expression. Returns matches as \c
        path:line:content with paths relative to the kernel root. \c
        Use subdir to restrict to a sub-tree (e.g. 'os') and \c
        max_results to cap the output (default 100).",
       #{ type: object,
          properties:
              #{ pattern:     #{type:string,
                                description:"POSIX ERE (-E) pattern"},
                 subdir:      #{type:string,
                                description:"Optional sub-directory of the \c
                                             kernel root to search in"},
                 max_results: #{type:integer, minimum:1, maximum:1000,
                                description:"Cap on number of result lines \c
                                             (default 100)"}
               },
          required: [pattern]
        }).

c_grep(Args, Text) :-
    atom_string(Pattern, Args.pattern),
    setting(mcp_swipl_kernel:c_source_root, Root),
    (   SubdirS = Args.get(subdir), SubdirS \== ""
    ->  atom_string(Subdir, SubdirS),
        directory_file_path(Root, Subdir, SearchDir)
    ;   SearchDir = Root
    ),
    Max = Args.get(max_results, 100),
    run_grep(Pattern, SearchDir, Raw),
    split_string(Raw, "\n", "", Lines0),
    exclude(=(""), Lines0, Lines1),
    take(Max, Lines1, Lines),
    length(Lines, N),
    length(Lines1, NTotal),
    strip_prefix(Lines, Root, Stripped),
    atomics_to_string(Stripped, "\n", Body),
    (   N < NTotal
    ->  format(string(Text), "~w of ~w matches:~n~w", [N, NTotal, Body])
    ;   format(string(Text), "~w matches:~n~w", [N, Body])
    ).

run_grep(Pattern, Dir, Output) :-
    process_create(path(grep),
                   [ '-rnE',
                     '--include=*.c', '--include=*.h',
                     '--', Pattern, Dir ],
                   [ stdout(pipe(Out)),
                     stderr(null),
                     process(PID)
                   ]),
    setup_call_cleanup(
        true,
        read_string(Out, _, Output),
        close(Out)),
    process_wait(PID, _Status).

take(0, _, []) :- !.
take(_, [], []) :- !.
take(N, [H|T0], [H|T]) :-
    N1 is N - 1,
    take(N1, T0, T).

exclude(_, [], []).
exclude(P, [H|T0], R) :-
    (   call(P, H)
    ->  exclude(P, T0, R)
    ;   R = [H|T1],
        exclude(P, T0, T1)
    ).

strip_prefix([], _, []).
strip_prefix([L0|T0], Prefix, [L|T]) :-
    (   atom_concat(Prefix, Rest, L0)
    ->  (   atom_concat('/', Rest1, Rest)
        ->  L = Rest1
        ;   L = Rest
        )
    ;   string_concat(Prefix, Rest, L0)
    ->  (   string_concat("/", Rest1, Rest)
        ->  L = Rest1
        ;   L = Rest
        )
    ;   L = L0
    ),
    strip_prefix(T0, Prefix, T).


:- mcp_tool(
       c_function_defs,
       "List function definitions in a SWI-Prolog C kernel source file. \c
        Detects the SWI style where the line `{` at column 0 follows \c
        a signature ending in `)`, plus PRED_IMPL(...) built-in entries. \c
        The file path may be absolute or relative to the kernel root.",
       #{ type: object,
          properties:
              #{ file: #{type:string,
                         description:"C source file (relative to the kernel \c
                                      root or absolute)"} },
          required: [file]
        }).

c_function_defs(Args, Text) :-
    atom_string(FileIn, Args.file),
    resolve_kernel_file(FileIn, Path),
    (   exists_file(Path)
    ->  scan_function_defs(Path, Defs),
        format_function_defs(Path, Defs, Text)
    ;   format(string(Text), "File not found: ~w", [Path])
    ).

resolve_kernel_file(File, File) :-
    is_absolute_file_name(File), !.
resolve_kernel_file(File, Path) :-
    setting(mcp_swipl_kernel:c_source_root, Root),
    directory_file_path(Root, File, Path).

scan_function_defs(Path, Defs) :-
    setup_call_cleanup(
        open(Path, read, In, [encoding(utf8)]),
        read_lines(In, Lines),
        close(In)),
    function_defs(Lines, 1, "", Defs).

read_lines(Stream, Lines) :-
    read_string(Stream, _, Body),
    split_string(Body, "\n", "", Lines).

function_defs([], _, _, []).
function_defs([Line|Rest], N, Prev, Defs) :-
    N1 is N + 1,
    (   is_open_brace_line(Line),
        sig_terminator(Prev)
    ->  Defs = [def(N, Prev)|More],
        function_defs(Rest, N1, Line, More)
    ;   pred_impl_line(Line, Spec)
    ->  Defs = [pred_impl(N, Spec)|More],
        function_defs(Rest, N1, Line, More)
    ;   function_defs(Rest, N1, Line, Defs)
    ).

is_open_brace_line(Line) :-
    string_length(Line, L), L >= 1,
    sub_string(Line, 0, 1, _, "{").

sig_terminator(Prev) :-
    string_concat(Trimmed, "", Prev),
    sub_string(Trimmed, _, 1, 0, ")").

pred_impl_line(Line, Spec) :-
    sub_string(Line, B, _, _, "PRED_IMPL("),
    !,
    Start is B + 10,
    sub_string(Line, Start, _, 0, Rest),
    sub_string(Rest, 0, End, _, ")"),
    sub_string(Rest, 0, End, _, Spec).

format_function_defs(Path, Defs, Text) :-
    length(Defs, N),
    findall(D, member(D, Defs), DefsCp),
    with_output_to(string(Text),
                   ( format("File: ~w~n", [Path]),
                     format("Definitions: ~d~n~n", [N]),
                     format_defs(DefsCp)
                   )).

format_defs([]).
format_defs([def(Line, Sig)|T]) :-
    format("  line ~d: ~w~n", [Line, Sig]),
    format_defs(T).
format_defs([pred_impl(Line, Spec)|T]) :-
    format("  line ~d: PRED_IMPL(~w)~n", [Line, Spec]),
    format_defs(T).
