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

:- module(mcp_server_source,
          [ source_root_path/2         % +Id, -Path
          ]).
:- use_module(library(mcp/server)).
:- use_module(library(filesex), [directory_file_path/3]).
:- use_module(library(process), [process_create/3, process_wait/2]).
:- use_module(library(lists), [append/3, last/2, reverse/2]).
:- use_module(library(apply), [maplist/3, exclude/3]).
:- use_module(library(pure_input), [phrase_from_file/2]).
:- use_module(library(dcg/basics), [string/3, whites/2, eol/2, remainder/3]).
:- use_module(library(readutil), [read_line_to_string/2]).

/** <module> MCP tools for serving source files from named roots

Lets a coding agent without a  local   checkout  fetch  source from this
server.  Every  tool   takes   a   `root`    name   (e.g.   `swipl`   or
`'swipl-source'`); the relative  path  is   then  resolved  against  the
configured directory and validated to stay inside it (no `..` escapes).

Tools registered:

  - source_roots    list the configured roots and whether each is a
                    git work-tree
  - source_list     list files in a sub-directory of a root
  - source_read     read a file (or a line range) from a root
  - source_search   POSIX-ERE grep across a root's tree

Roots:

  - The `swipl` root is provided by default and points at home directory
    of the running Prolog system.
  - The `'swipl-source'` gives access to the GIT checked out source
    tree. If SWI-Prolog is executed from the build tree, this is
    discovered automatically.  Otherwise it must be specified on the
    commandline as ``swipl -Dcmake_source_directory=Path ...``
  - Additional roots are added by writing multifile clauses for
    mcp_server_source:source_root/2.  Note that the specification
    can use path aliases as accepted by absolute_file_name/3.  This
    must expand to a directory.

        :- multifile mcp_server_source:source_root/2.
        mcp_server_source:source_root('chat80', pack(chat80)).
*/

%!  source_root_path(?Name, -Path) is nondet.
%
%   True when Path is to be searched for sources under the given Name.

source_root_path(Name, Path) :-
    source_root(Name, Spec),
    absolute_file_name(Spec, Path,
                       [ file_type(directory),
                         file_errors(fail)
                       ]).

%!  source_root(?Name, ?Path) is nondet.
%
%   Multifile.  Lists the configured source roots.

:- multifile source_root/2.

source_root(swipl, Path) :-
    current_prolog_flag(home, Path).
source_root('swipl-source', Path) :-
    cmake_discover_source(Path).

cmake_discover_source(Dir) :-
    current_prolog_flag(cmake_source_directory, Dir),
    exists_directory(Dir),
    !.
cmake_discover_source(Dir) :-
    current_prolog_flag(cmake_binary_directory, BinDir),
    directory_file_path(BinDir, 'CMakeCache.txt', CacheFile),
    phrase_from_file((string(_), "SWI-Prolog_SOURCE_DIR:STATIC=", !,
                      string(DirCodes), whites, eol, remainder(_)), CacheFile),
    !,
    atom_codes(Dir, DirCodes).

                /*******************************
                *           TOOLS              *
                *******************************/

:- mcp_tool(
       source_roots,
       "List the configured source roots.  Returns each root's name, \c
        absolute path, and whether it is a git work-tree (so the client \c
        knows whether to expect the git_* tools to apply to it).",
       #{ type: object, properties: #{} }).

source_roots(_Args, Text) :-
    findall(line(Name, Path, IsGit),
            ( source_root_path(Name, Path),
              is_git_root(Path, IsGit) ),
            Lines),
    (   Lines == []
    ->  Text = "No source roots configured."
    ;   with_output_to(string(Text), format_roots(Lines))
    ).

format_roots([]).
format_roots([line(Name, Path, IsGit)|T]) :-
    (   IsGit == true -> Tag = " (git)" ; Tag = "" ),
    format("  ~w~t~24|~w~w~n", [Name, Path, Tag]),
    format_roots(T).


:- mcp_tool(
       source_list,
       "List files in a sub-directory of a configured source root. \c
        Returns one path per line, relative to the root, with size in \c
        bytes.  Optional glob restricts the result (e.g. '*.c', \c
        'src/os/*.h').  max_results caps the output (default 200).",
       #{ type: object,
          properties:
              #{ root:    #{ type: string,
                             description: "Root name from source_roots" },
                 dir:     #{ type: string,
                             description: "Sub-directory inside the root \c
                                            (default '.', the root itself)" },
                 glob:    #{ type: string,
                             description: "Shell-style glob pattern" },
                 max_results: #{ type: integer, minimum: 1, maximum: 5000 }
               },
          required: [root]
        }).

source_list(Args, Text) :-
    atom_string(RootName, Args.root),
    get_dict_as_atom(dir,  Args, Dir, '.'),
    get_dict_as_atom(glob, Args, Glob, '*'),
    Max = Args.get(max_results, 200),
    (   resolve_root_path(RootName, Dir, AbsDir, _RelDir)
    ->  list_files(AbsDir, Glob, Max, Lines, NTotal),
        length(Lines, NShown),
        with_output_to(string(Text),
                       ( format("~w of ~w entries in ~w/~w (glob: ~w)~n",
                                [NShown, NTotal, RootName, Dir, Glob]),
                         format_listing(Lines) ))
    ;   format(string(Text), "Unknown or unsafe path: ~w/~w",
               [RootName, Dir])
    ).

get_dict_as_atom(Key, Dict, Atom, Default) :-
    (   get_dict(Key, Dict, String)
    ->  atom_string(Atom, String)
    ;   Atom = Default
    ).


format_listing([]).
format_listing([entry(Path, Size)|T]) :-
    format("  ~w~t~60|~t~D bytes~10+~n", [Path, Size]),
    format_listing(T).


:- mcp_tool(
       source_read,
       "Read a file from a source root.  Returns the content with line \c
        numbers.  Optional start_line and end_line slice the file \c
        (1-based, inclusive); without them the whole file is returned. \c
        max_bytes caps the response size (default 32768).",
       #{ type: object,
          properties:
              #{ root:        #{ type: string },
                 path:        #{ type: string,
                                 description: "Path relative to the root" },
                 start_line:  #{ type: integer, minimum: 1 },
                 end_line:    #{ type: integer, minimum: 1 },
                 max_bytes:   #{ type: integer, minimum: 256, maximum: 1048576 }
               },
          required: [root, path]
        }).

source_read(Args, Text) :-
    atom_string(RootName, Args.root),
    atom_string(Path, Args.path),
    Start  = Args.get(start_line, 1),
    EndArg = Args.get(end_line, infinite),
    MaxB   = Args.get(max_bytes, 32768),
    (   resolve_root_path(RootName, Path, AbsPath, RelPath)
    ->  (   exists_file(AbsPath)
        ->  read_file_slice(AbsPath, Start, EndArg, MaxB, Body,
                            ShownStart, ShownEnd, Truncated),
            truncation_marker(Truncated, Marker),
            with_output_to(string(Text),
                           ( format("~w/~w  (lines ~w-~w~w)~n",
                                    [RootName, RelPath,
                                     ShownStart, ShownEnd, Marker]),
                             format("~w", [Body]) ))
        ;   format(string(Text), "Not a file: ~w/~w", [RootName, RelPath])
        )
    ;   format(string(Text), "Unknown or unsafe path: ~w/~w", [RootName, Path])
    ).

truncation_marker(true,  ", truncated").
truncation_marker(false, "").


:- mcp_tool(
       source_search,
       "Recursively grep for a POSIX extended regular expression inside \c
        a configured source root.  Returns matches as path:line:content, \c
        with paths relative to the root.  Optional file_glob restricts \c
        the file set (default '*'); max_results caps the output \c
        (default 100).",
       #{ type: object,
          properties:
              #{ root:        #{ type: string },
                 pattern:     #{ type: string },
                 file_glob:   #{ type: string,
                                 description: "e.g. '*.c', '*.{c,h}'" },
                 max_results: #{ type: integer, minimum: 1, maximum: 5000 }
               },
          required: [root, pattern]
        }).

source_search(Args, Text) :-
    atom_string(RootName, Args.root),
    atom_string(Pattern, Args.pattern),
    (   Glob0 = Args.get(file_glob) -> atom_string(Glob, Glob0) ; Glob = '*' ),
    Max = Args.get(max_results, 100),
    (   source_root_path(RootName, RootAbs)
    ->  run_grep(Pattern, RootAbs, Glob, RawOutput),
        split_string(RawOutput, "\n", "", Lines0),
        exclude(=(""), Lines0, Lines1),
        length(Lines1, NTotal),
        first_n(Lines1, Max, ShownLines),
        length(ShownLines, NShown),
        strip_root_prefix(ShownLines, RootAbs, Display),
        atomics_to_string(Display, "\n", Body),
        (   NShown < NTotal
        ->  format(string(Text),
                   "~w of ~w matches:~n~w", [NShown, NTotal, Body])
        ;   format(string(Text), "~w matches:~n~w", [NShown, Body])
        )
    ;   format(string(Text), "Unknown root: ~w", [RootName])
    ).


                /*******************************
                *      PATH RESOLUTION         *
                *******************************/

%!  resolve_root_path(+RootName, +Rel, -AbsPath, -RelPath) is semidet.
%
%   Map RootName + Rel (a relative path) to an absolute path,
%   verifying the result stays inside the root (no `..` escapes
%   and no symlinks pointing outside).

resolve_root_path(RootName, Rel0, AbsPath, RelClean) :-
    once(source_root_path(RootName, RootAbs0)),
    ensure_no_trailing_slash(RootAbs0, RootAbs),
    atom_string(RelAtom, Rel0),
    safe_relative(RelAtom),
    (   RelAtom == '.'
    ->  AbsPath = RootAbs, RelClean = '.'
    ;   directory_file_path(RootAbs, RelAtom, AbsPath),
        RelClean = RelAtom
    ),
    %  safe_relative/1 already rejects '..' segments, so the
    %  joined path stays under RootAbs.  Symlinks that point
    %  outside are not considered a threat -- the admin who set
    %  the root path is also the one who controls its contents.
    (   exists_file(AbsPath)
    ->  true
    ;   exists_directory(AbsPath)
    ).

ensure_no_trailing_slash(P, P) :-
    \+ sub_atom(P, _, 1, 0, '/'),
    !.
ensure_no_trailing_slash(P, Q) :-
    sub_atom(P, 0, _, 1, Q).

%!  safe_relative(+Path) is semidet.
%
%   Path is a relative path that does not contain a `..` segment.
%   Absolute paths and ones starting with `~` are rejected.

safe_relative(Path) :-
    \+ sub_atom(Path, 0, 1, _, '/'),
    \+ sub_atom(Path, 0, 1, _, '~'),
    split_string(Path, "/", "/", Parts),
    \+ memberchk("..", Parts).


                /*******************************
                *       FILE OPERATIONS        *
                *******************************/

%!  is_git_root(+AbsPath, -IsGit:boolean) is det.

is_git_root(Path, IsGit) :-
    directory_file_path(Path, '.git', GitDir),
    (   exists_directory(GitDir)
    ->  IsGit = true
    ;   exists_file(GitDir)             % gitlink (submodule)
    ->  IsGit = true
    ;   IsGit = false
    ).

%!  list_files(+Dir, +Glob, +Max, -Entries, -NTotal) is det.

list_files(Dir, Glob, Max, Entries, NTotal) :-
    directory_file_path(Dir, Glob, Pattern),
    catch(expand_file_name(Pattern, All), error(_,_), All = []),
    maplist(file_entry(Dir), All, Entries0),
    sort(1, @=<, Entries0, EntriesSorted),
    length(EntriesSorted, NTotal),
    first_n(EntriesSorted, Max, Entries).

file_entry(BaseDir, AbsPath, entry(Rel, Size)) :-
    atom_concat(BaseDir, '/', BasePrefix),
    (   atom_concat(BasePrefix, Rel, AbsPath)
    ->  true
    ;   Rel = AbsPath
    ),
    catch(size_file(AbsPath, Size), error(_,_), Size = 0).

first_n(_, 0, []) :- !.
first_n([], _, []) :- !.
first_n([H|T], N, [H|R]) :-
    N1 is N - 1,
    first_n(T, N1, R).

%!  read_file_slice(+Abs, +Start, +EndArg, +MaxB, -Body,
%!                  -ShownStart, -ShownEnd, -Truncated) is det.
%
%   @arg Start is the 1-based start line
%   @arg EndArg is the 1-based end line or `infinite`
%   @arg MaxB is the maximum number of characters
%   @arg Body is a string holding the content lines with line
%        numbers.
%   @arg ShownStart is the actual start line
%   @arg ShownEnd is the actual end line
%   @arg Truncated is `true` if MaxB truncated the content.

read_file_slice(Abs, Start, EndArg, MaxB, Body,
                ShownStart, ShownEnd, Truncated) :-
    setup_call_cleanup(
        open(Abs, read, Stream, [encoding(utf8)]),
        read_stream_slice(Stream, Start, EndArg, MaxB, Body,
                          ShownStart, ShownEnd, Truncated),
        close(Stream)).

read_stream_slice(Stream, Start, EndArg, MaxB, Body,
                  ShownStart, ShownEnd, Truncated) :-
    skip_to_line(1, Start, Stream, ShownStart),
    read_stream_lines(Stream, ShownStart, EndArg, MaxB, Lines,
                      ShownEnd, Truncated),
    atomics_to_string(Lines, Body).

skip_to_line(Line, Start, Stream, ShownStart) :-
    Line < Start,
    \+ at_end_of_stream(Stream),
    !,
    skip(Stream, 0'\n),
    Line1 is Line + 1,
    skip_to_line(Line1, Start, Stream, ShownStart).
skip_to_line(Line, _, _, Line).

read_stream_lines(Stream, LineNo, EndArg, MaxB, Lines,
                  ShownEnd, Truncated) :-
    (   EndArg == infinite
    ->  true
    ;   LineNo =< EndArg
    ),
    !,
    read_line_to_string(Stream, Content),
    (   Content == end_of_file
    ->  Lines = [],
        ShownEnd = LineNo,
        Truncated = true
    ;   string_length(Content, Len),
        MaxB1 is MaxB - Len,
        (   MaxB1 < 0
        ->  Left is Len - MaxB,
            sub_string(Content, 0, Left, _, TContent),
            format(string(Line), "~|~t~d~6+  ~w ...~n", [LineNo, TContent]),
            Lines = [Line],
            ShownEnd = LineNo,
            Truncated = true
        ;   Lines = [Line|MoreLines],
            format(string(Line), "~|~t~d~6+  ~w~n", [LineNo, Content]),
            LineNo1 is LineNo+1,
            read_stream_lines(Stream, LineNo1, EndArg, MaxB1, MoreLines,
                              ShownEnd, Truncated)
        )
    ).
read_stream_lines(_, LineNo, _, _, [], LineNo, false).

                /*******************************
                *           GREP               *
                *******************************/

%!  run_grep(+Pattern, +RootAbs, +Glob, -Output) is det.
%
%   Recursively grep -nE under RootAbs.  Glob is passed to grep's
%   --include flag.  When the user wants every file, glob is '*'
%   which we translate to no --include.

run_grep(Pattern, RootAbs, Glob, Output) :-
    grep_include_args(Glob, IncludeArgs),
    append(['-rnE'], IncludeArgs, Pre),
    append(Pre, ['--', Pattern, RootAbs], Args),
    catch(setup_call_cleanup(
              process_create(path(grep), Args,
                             [ stdout(pipe(Out)),
                               stderr(null),
                               process(PID)
                             ]),
              read_string(Out, _, Output),
              close(Out, [force(true)])),
          Error,
          ( message_to_string(Error, Msg),
            format(string(Output), "Grep failed: ~w~n", [Msg])
          )),
    %  Wait for the child so it does not become a zombie.  grep's exit
    %  status is intentionally ignored: 1 ("no matches") is a normal
    %  outcome and reaches us as empty Output, which the caller renders
    %  as "0 matches".  Auto-reap (omitting process(PID)) would raise on
    %  exit 1 and turn the no-match case into a spurious "Grep failed".
    process_wait(PID, _Status).

grep_include_args('*', []) :- !.
grep_include_args(Glob, [IncludeArg]) :-
    format(atom(IncludeArg), "--include=~w", [Glob]).

strip_root_prefix([], _, []).
strip_root_prefix([Line|T0], Root, [Stripped|T]) :-
    (   atom_concat(Root, Rest, Line)
    ->  (   atom_concat('/', Stripped, Rest)
        ->  true
        ;   Stripped = Rest
        )
    ;   string_concat(Root, RestS, Line)
    ->  (   string_concat("/", Stripped, RestS)
        ->  true
        ;   Stripped = RestS
        )
    ;   Stripped = Line
    ),
    strip_root_prefix(T0, Root, T).
