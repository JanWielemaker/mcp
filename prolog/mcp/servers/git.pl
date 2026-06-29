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

:- module(mcp_server_git, []).
:- use_module(library(mcp/server)).
:- use_module(library(mcp/servers/source), [source_root_path/2]).
:- use_module(library(process), [process_create/3, process_wait/2]).
:- use_module(library(filesex), [directory_file_path/3]).
:- use_module(library(lists), [append/3, append/2]).

/** <module> MCP tools for read-only git access on configured source roots

Mirrors the read-only subset of git so a coding agent (with HTTP-only
access to this server) can investigate history without a checkout.

Each tool resolves a `root` name through the same registry as the
source server (mcp_server_source:source_root/2) and rejects roots
that are not git work-trees.  The git CLI is invoked via
process_create/3 with an explicit argv list; no shell, no command
injection.  Only the read-only subcommands (log, blame, show, diff,
grep, ls-tree, rev-parse) are reachable.

Tools registered:

  - git_log     recent commits, optionally restricted to one path
  - git_blame   line-by-line authorship for a range
  - git_show    a commit (diff) or a file at a commit
  - git_diff    diff between two refs, optionally restricted to a path
  - git_grep    git's own grep -- handles submodules natively
*/

:- mcp_tool(
       git_log,
       "Show recent commits in a source root.  Format per line: \c
        <abbrev-sha>  <author-date>  <author-name>  <subject>. \c
        Optional path restricts history to commits that touched that \c
        file or directory.  max defaults to 30; since (a git date \c
        spec like '2 weeks ago' or '2024-01-01') further restricts.",
       #{ type: object,
          properties:
              #{ root:  #{ type: string },
                 path:  #{ type: string,
                           description: "Optional path inside the root" },
                 max:   #{ type: integer, minimum: 1, maximum: 1000 },
                 since: #{ type: string,
                           description: "Git --since= value" }
               },
          required: [root]
        }).

git_log(Args, Text) :-
    git_root(Args, RootPath, RootName, Err),
    !,
    (   var(Err)
    ->  Max = Args.get(max, 30),
        Format = '--pretty=format:%h  %ad  %an  %s',
        DateOpt = '--date=short',
        with_optional_path(Args, PathArgs),
        with_optional_since(Args, SinceArgs),
        format(atom(MaxArg), "-n~w", [Max]),
        append([['log', MaxArg, Format, DateOpt],
                SinceArgs, PathArgs], Args1),
        run_git(RootPath, Args1, Output, Status),
        format_git_text(RootName, Status, Output, Text)
    ;   Text = Err
    ).


:- mcp_tool(
       git_blame,
       "Per-line authorship for a range in a file.  Output is git's \c
        --line-porcelain reformatted as `<sha>  <line>  <author>  \c
        <date>  <line text>`.  start_line / end_line are 1-based, \c
        inclusive.",
       #{ type: object,
          properties:
              #{ root:       #{ type: string },
                 path:       #{ type: string },
                 start_line: #{ type: integer, minimum: 1 },
                 end_line:   #{ type: integer, minimum: 1 }
               },
          required: [root, path, start_line, end_line]
        }).

git_blame(Args, Text) :-
    git_root(Args, RootPath, RootName, Err),
    !,
    (   var(Err)
    ->  atom_string(Path, Args.path),
        Start = Args.start_line,
        End   = Args.end_line,
        format(atom(Range), "-L~w,~w", [Start, End]),
        run_git(RootPath,
                ['blame', '--line-porcelain', Range, '--', Path],
                Output, Status),
        (   Status = exit(0)
        ->  format_blame(Output, Body),
            format(string(Text), "~w  ~w  lines ~w-~w:~n~w",
                   [RootName, Path, Start, End, Body])
        ;   format(string(Text), "git blame failed (~w):~n~w",
                   [Status, Output])
        )
    ;   Text = Err
    ).


:- mcp_tool(
       git_show,
       "Inspect a commit or a file at a commit.  Without `path`, runs \c
        `git show <commit>` (commit message + full diff).  With `path`, \c
        returns the file's content at that commit -- equivalent to \c
        `git show <commit>:<path>`.",
       #{ type: object,
          properties:
              #{ root:   #{ type: string },
                 commit: #{ type: string,
                            description: "sha, branch, tag, HEAD~N, ..." },
                 path:   #{ type: string,
                            description: "Optional path (file at commit)" }
               },
          required: [root, commit]
        }).

git_show(Args, Text) :-
    git_root(Args, RootPath, RootName, Err),
    !,
    (   var(Err)
    ->  atom_string(Commit, Args.commit),
        (   PathS = Args.get(path)
        ->  atom_string(Path, PathS),
            format(atom(Spec), "~w:~w", [Commit, Path]),
            run_git(RootPath, ['show', Spec], Output, Status),
            (   Status = exit(0)
            ->  format(string(Text), "~w  ~w@~w:~n~w",
                       [RootName, Path, Commit, Output])
            ;   format(string(Text), "git show failed (~w):~n~w",
                       [Status, Output])
            )
        ;   run_git(RootPath, ['show', Commit], Output, Status),
            (   Status = exit(0)
            ->  format(string(Text), "~w  show ~w:~n~w",
                       [RootName, Commit, Output])
            ;   format(string(Text), "git show failed (~w):~n~w",
                       [Status, Output])
            )
        )
    ;   Text = Err
    ).


:- mcp_tool(
       git_diff,
       "Diff between two refs.  ref1 is the base (older).  ref2 \c
        defaults to HEAD; combined they form `git diff ref1..ref2`. \c
        Optional path narrows the diff.",
       #{ type: object,
          properties:
              #{ root: #{ type: string },
                 ref1: #{ type: string },
                 ref2: #{ type: string,
                          description: "Default: HEAD" },
                 path: #{ type: string,
                          description: "Optional path" }
               },
          required: [root, ref1]
        }).

git_diff(Args, Text) :-
    git_root(Args, RootPath, RootName, Err),
    !,
    (   var(Err)
    ->  atom_string(Ref1, Args.ref1),
        get_dict_as_atom(ref2, Args, Ref2, 'HEAD'),
        format(atom(Range), "~w..~w", [Ref1, Ref2]),
        with_optional_path(Args, PathArgs),
        append(['diff', Range, '--'], PathArgs, Args1),
        run_git(RootPath, Args1, Output, Status),
        (   Status = exit(0)
        ->  format(string(Text), "~w  ~w..~w:~n~w",
                   [RootName, Ref1, Ref2, Output])
        ;   format(string(Text), "git diff failed (~w):~n~w",
                   [Status, Output])
        )
    ;   Text = Err
    ).


:- mcp_tool(
       git_grep,
       "Run git's own grep inside a root.  Faster than source_search \c
        because it only searches tracked files and respects \c
        .gitignore.  Optional ref searches a commit; \c
        recurse_submodules follows submodule trees.  max_results caps \c
        the output (default 100).",
       #{ type: object,
          properties:
              #{ root:               #{ type: string },
                 pattern:            #{ type: string },
                 ref:                #{ type: string,
                                        description: "Default: working tree" },
                 recurse_submodules: #{ type: boolean },
                 max_results:        #{ type: integer,
                                        minimum: 1, maximum: 5000 }
               },
          required: [root, pattern]
        }).

git_grep(Args, Text) :-
    git_root(Args, RootPath, RootName, Err),
    !,
    (   var(Err)
    ->  atom_string(Pattern, Args.pattern),
        Max = Args.get(max_results, 100),
        Recurse = Args.get(recurse_submodules, false),
        (   Recurse == true
        ->  RecArgs = ['--recurse-submodules']
        ;   RecArgs = []
        ),
        (   RefS = Args.get(ref) -> atom_string(Ref, RefS), RefArgs = [Ref]
        ;   RefArgs = []
        ),
        append([['grep', '-nE'], RecArgs, ['-e', Pattern], RefArgs], Args1),
        run_git(RootPath, Args1, Output, Status),
        format_grep_text(RootName, Status, Output, Max, Text)
    ;   Text = Err
    ).


                /*******************************
                *           HELPERS            *
                *******************************/

%!  git_root(+Args, -RootPath, -RootName, -Err) is det.
%
%   Resolve the root name in Args to its filesystem path AND verify
%   it is a git work-tree.  On success, Err stays unbound.  On
%   failure, Err is a human-readable error string and the other
%   args may be unbound.

git_root(Args, RootPath, RootName, Err) :-
    atom_string(RootName, Args.root),
    (   source_root_path(RootName, RootPath)
    ->  (   is_git_work_tree(RootPath)
        ->  true
        ;   format(string(Err), "Root ~w is not a git work-tree",
                   [RootName])
        )
    ;   format(string(Err), "Unknown root: ~w", [RootName])
    ).

is_git_work_tree(Path) :-
    directory_file_path(Path, '.git', Dot),
    (   exists_directory(Dot) ; exists_file(Dot) ),
    !.

%!  run_git(+RootPath, +ArgsList, -Output, -Status) is det.
%
%   Run `git -C <RootPath> <ArgsList...>` and capture stdout+stderr.

run_git(RootPath, GitArgs, Output, Status) :-
    append(['-C', RootPath], GitArgs, FullArgs),
    catch(setup_call_cleanup(
              process_create(path(git), FullArgs,
                             [ stdout(pipe(Out)),
                               stderr(pipe(Err)),
                               process(PID)
                             ]),
              read_stout_and_stderr(Out, Err, OutS, ErrS),
              ( close(Out, [force(true)]),
                close(Err, [force(true)])
              )),
          Error,
          ( message_to_string(Error, Msg),
            format(string(Output), "Running git failed: ~w~n", [Msg])
          )),
    process_wait(PID, Status),
    (   ErrS == ""
    ->  Output = OutS
    ;   format(string(Output), "~w~n[stderr]~n~w", [OutS, ErrS])
    ).

read_stout_and_stderr(Out, Err, OutS, ErrS) :-
    thread_self(Me),
    thread_create(( read_string(Err, _, ErrS),
                    thread_send_message(Me, err(ErrS))
                  ), Id, []),
    read_string(Out, _, OutS),
    thread_get_message(err(ErrS)),
    thread_join(Id).


                /*******************************
                *          FORMATTERS          *
                *******************************/

format_git_text(RootName, exit(0), Body, Text) :- !,
    format(string(Text), "~w:~n~w", [RootName, Body]).
format_git_text(_RootName, Status, Body, Text) :-
    format(string(Text), "git failed (~w):~n~w", [Status, Body]).

format_grep_text(RootName, exit(0), Body, Max, Text) :- !,
    split_string(Body, "\n", "", Lines0),
    exclude_empty(Lines0, Lines),
    length(Lines, NTotal),
    take_n(Lines, Max, Shown),
    length(Shown, NShown),
    atomics_to_string(Shown, "\n", BodyShown),
    (   NShown < NTotal
    ->  format(string(Text), "~w: ~w of ~w matches:~n~w",
               [RootName, NShown, NTotal, BodyShown])
    ;   format(string(Text), "~w: ~w matches:~n~w",
               [RootName, NShown, BodyShown])
    ).
format_grep_text(_RootName, exit(1), "", _, "No matches.") :- !.
format_grep_text(_RootName, Status, Body, _, Text) :-
    format(string(Text), "git grep failed (~w):~n~w", [Status, Body]).

exclude_empty([], []).
exclude_empty([""|T], R) :- !, exclude_empty(T, R).
exclude_empty([H|T], [H|R]) :- exclude_empty(T, R).

take_n(_, 0, []) :- !.
take_n([], _, []) :- !.
take_n([H|T], N, [H|R]) :- N1 is N - 1, take_n(T, N1, R).


%!  format_blame(+Porcelain, -Pretty) is det.
%
%   Parse git blame --line-porcelain output (one record per line)
%   into a compact "sha line  author  date  text" rendering.

%  Parser is defensive: anything off shape just falls through to
%  the catch-all, which records the line raw.  A malformed
%  porcelain record will never crash the proxy.

format_blame(Porcelain, Pretty) :-
    split_string(Porcelain, "\n", "", Lines),
    catch(blame_records(Lines, Records),
          error(_,_), Records = []),
    with_output_to(string(Pretty), print_blame_records(Records)).

blame_records([], []).
blame_records([HeaderLine|HeaderRest], [Rec|Rest]) :-
    is_blame_header(HeaderLine, Sha, FinalLine),
    !,
    collect_record(HeaderRest, #{}, Fields, RemRest),
    ( AuthS = Fields.get(author) -> atom_string(Author, AuthS) ; Author = "?" ),
    ( DateS = Fields.get(author_time) -> Date = DateS ; Date = "?" ),
    ( RemRest = [TLine|RemRest2],
      string_length(TLine, L), L >= 1,
      sub_string(TLine, 0, 1, _, "\t")
    ->  sub_string(TLine, 1, _, 0, Text), Next = RemRest2
    ;   Text = "", Next = RemRest
    ),
    Rec = rec(Sha, FinalLine, Author, Date, Text),
    blame_records(Next, Rest).
blame_records([_|T], Rest) :-
    blame_records(T, Rest).

is_blame_header(Line, Sha, FinalLine) :-
    split_string(Line, " ", "", Parts),
    Parts = [ShaS, OrigS, FinalS|_],
    string_length(ShaS, ShaLen),
    ShaLen >= 7,
    number_string(_, OrigS),
    number_string(FinalLine, FinalS),
    atom_string(Sha, ShaS).

collect_record([Line|T], Acc, Out, Rest) :-
    split_string(Line, " ", "", [Key|Vs]),
    Vs \== [],
    atom_string(KeyA, Key),
    field_key(KeyA, NormKey),
    !,
    atomics_to_string(Vs, " ", Value),
    put_dict(NormKey, Acc, Value, Acc2),
    collect_record(T, Acc2, Out, Rest).
collect_record(Rest, Acc, Acc, Rest).

field_key(author,            author).
field_key('author-mail',     author_mail).
field_key('author-time',     author_time).
field_key('author-tz',       author_tz).
field_key(committer,         committer).
field_key('committer-mail',  committer_mail).
field_key('committer-time',  committer_time).
field_key('committer-tz',    committer_tz).
field_key(summary,           summary).
field_key(previous,          previous).
field_key(filename,          filename).
field_key(boundary,          boundary).

print_blame_records([]).
print_blame_records([rec(Sha, FinalLine, Author, Date, Text)|T]) :-
    sub_string(Sha, 0, 8, _, ShortSha),
    format("  ~w  ~|~t~w~6+  ~w~t~28|  ~w  ~w~n",
           [ShortSha, FinalLine, Author, Date, Text]),
    print_blame_records(T).


with_optional_path(Args, [Path]) :-
    PathS = Args.get(path),
    !,
    atom_string(Path, PathS).
with_optional_path(_, []).

with_optional_since(Args, ['--since', Since]) :-
    SinceS = Args.get(since),
    !,
    atom_string(Since, SinceS).
with_optional_since(_, []).

get_dict_as_atom(Key, Dict, Atom, Default) :-
    (   get_dict(Key, Dict, String)
    ->  atom_string(Atom, String)
    ;   Atom = Default
    ).
