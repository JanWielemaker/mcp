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

:- module(mcp_server_prolog_help, []).
:- use_module(library(mcp/server)).
:- use_module(library(mcp/messages), [run_collect_messages/4]).
:- use_module(library(mcp/servers/source), [source_root_path/2]).
:- use_module(library(yall)).
:- use_module(library(apply), [maplist/3, include/3, maplist/2]).
:- use_module(library(help), [help_text/2, help_apropos/4]).
:- use_module(library(listing), [listing/2, portray_clause/1]).
:- use_module(library(prolog_xref)).
:- use_module(library(prolog_deps), [file_autoload_directives/3]).
:- use_module(library(prolog_pack), [pack_property/2]).
:- use_module(library(lists), [member/2, list_to_set/2, append/3]).
:- use_module(library(edit), []).
:- use_module(library(explain), [explain/2 as imp_explain]).
:- use_module(library(http/html_write), [html//1, print_html/1]).
:- use_module(library(sgml), [load_html/3]).
:- use_module(library(lynx/html_text), [html_text/2]).
:- use_module(pldoc(doc_man), [man_page//2]).
:- use_module(pldoc(man_index), [man_object_property/2]).
:- use_module(pldoc(doc_process), [comment_modes/2]).
:- use_module(library(debug), [debug/3]).
:- use_module(library(filesex), [directory_file_path/3, directory_member/3]).
:- use_module(library(prolog_code), [pi_head/2, head_name_arity/3]).

/** <module> MCP tools for introspecting SWI-Prolog

Loading this module registers MCP tools and a resource template suitable
for an LLM coding assistant working on Prolog code.

Tools registered:

  - predicate_help     -- manual entry for Name/Arity
  - apropos            -- search the manual
  - predicate_listing  -- source code of a predicate
  - predicate_property -- structured metadata
  - pldoc_signature    -- PlDoc mode + determinism + meta_predicate
  - predicate_property_summary -- curated grouped predicate_property/2 view
  - file_xref          -- analyze a source file
  - file_autoload      -- compute the :- autoload/2 block a file needs
  - module_exports     -- list a module's exports + one-line summaries
  - predicate_callers  -- xref a directory tree to find where a
                          predicate is called from
  - file_check         -- xref a file and report syntax/singleton/etc
                          warnings plus undefined call sites
  - pack_info          -- info on an installed pack
  - manual_section     -- body of a manual section by anchor
  - locate_source      -- source file/line for a predicate (Prolog or C)
  - explain            -- what the system knows about a term (uses
                          library(explain): type, predicates, refs)

Resource templates:

  - prolog://help/{name}/{arity} -- read manual entry as a resource
  - prolog://section/{id}        -- read manual section body as a resource
*/

                /*******************************
                *           TOOLS              *
                *******************************/

:- mcp_tool(
       predicate_help,
       "Return the SWI-Prolog manual entry for a predicate as plain text.",
       #{ type: object,
          properties:
              #{ name:  #{type:string, description:"Predicate name"},
                 arity: #{type:integer, minimum:0,
                          description:"Predicate arity"}
               },
          required: [name, arity]
        }).

predicate_help(Args, Text) :-
    NameS = Args.name,
    Arity = Args.arity,
    atom_string(Name, NameS),
    (   help_text(Name/Arity, Text)
    ->  true
    ;   format(string(Text), "No manual entry for ~w/~w", [Name, Arity])
    ).


:- mcp_tool(
       apropos,
       "Search the SWI-Prolog manual for predicates whose name or summary \c
        matches a query.  max_results caps the output (default 20).",
       #{ type: object,
          properties:
              #{ query:       #{type:string},
                 max_results: #{type:integer, minimum:1, maximum:1000,
                                description:"Cap on matches (default 20)"}
               },
          required: [query]
        }).

apropos(Args, Text) :-
    QueryS = Args.query,
    atom_string(Q, QueryS),
    Max = Args.get(max_results, 20),
    findall(Score-(Obj-Summary),
            help_apropos(Q, Obj, Summary, Score),
            Pairs0),
    (   Pairs0 == []
    ->  format(string(Text), "No matches for ~q", [QueryS])
    ;   sort(1, >=, Pairs0, Pairs1),
        length(Pairs1, NTotal),
        first_n(Pairs1, Max, Top),
        length(Top, NShown),
        with_output_to(string(Text),
                       ( maplist(format_apropos, Top),
                         (   NShown < NTotal
                         ->  format("(showing ~w of ~w matches)~n",
                                    [NShown, NTotal])
                         ;   true
                         )
                       ))
    ).

first_n([], _, []) :- !.
first_n(_, 0, []) :- !.
first_n([H|T], N, [H|R]) :-
    N1 is N - 1,
    first_n(T, N1, R).

format_apropos(_-(Obj-Summary)) :-
    format("~q  --  ~w~n", [Obj, Summary]).


:- mcp_tool(
       predicate_listing,
       "Return the source code (clauses) of a defined predicate.  With \c
        source=true, list clauses as they appear in the source files \c
        rather than decompiled; this is particularly useful for multifile \c
        predicates, where it collects clauses across all contributing \c
        files with file/line comments.",
       #{ type: object,
          properties:
              #{ name:   #{type:string},
                 arity:  #{type:integer, minimum:0},
                 module: #{type:string,
                           description:"Optional module qualifier"},
                 source: #{type:boolean,
                           description:"List original source rather than \c
                                        decompiled clauses (default false)"}
               },
          required: [name, arity]
        }).

predicate_listing(Args, Text) :-
    args_pi(Args, PI),
    (   Args.get(source) == true
    ->  Options = [source(true)]
    ;   Options = []
    ),
    with_output_to(string(Text),
                   catch(@(listing(PI, Options), user),
                         Error,
                         (   message_to_string(Error, Msg),
                             format("Error: ~w~n", [Msg])
                         ))).

%!  args_pi(+Args:dict, -PI:pi) is det.
%
%   Extract the name and optional arity and module to create a predicate
%   indicator as Module:Name/Arity. Module  and/or   Arity  may  be left
%   unbound. Tools that need a  full   specification  can  require these
%   fields to be present in their JSON Schema type specification.

args_pi(Args, Module:Name/Arity) :-
    atom_string(Name, Args.name),
    Arity = Args.get(arity, _),
    ignore(atom_string(Module, Args.get(module))).

:- mcp_tool(
       predicate_info,
       "Raw, unfiltered predicate_property/2 snapshot for a predicate \c
        (defined, dynamic, iso, autoload source, number_of_clauses, \c
        size, last_modified_generation, ...).  Use \c
        predicate_property_summary instead for a curated, grouped \c
        view of the same information.",
       #{ type: object,
          properties:
              #{ name:  #{type:string},
                 arity: #{type:integer, minimum:0},
                 module: #{type:string}
               },
          required: [name, arity]
        }).

predicate_info(Args, Text) :-
    args_pi(Args, PI),
    pi_head(PI, QHead),
    findall(P, predicate_property(QHead, P), Props0),
    sort(Props0, Props),
    (   Props == []
    ->  format(string(Text), "No such predicate: ~q", [PI])
    ;   with_output_to(string(Text), format_props(QHead, Props))
    ).




format_props(QHead, Props) :-
    format("~q:~n", [QHead]),
    forall(member(P, Props),
           format("  - ~q~n", [P])).


:- mcp_tool(
       pldoc_signature,
       "PlDoc mode declarations and determinism for a predicate, plus \c
        its :- meta_predicate spec.\n\n\c
        Mode declarations come from the PlDoc %! / /** ... */ comments \c
        in the source file.  Source resolution: if 'file' is given, \c
        xref that file; otherwise xref the file that defines the \c
        predicate (via predicate_property/2 file/1).\n\n\c
        Determinism is one of det / semidet / nondet / multi / failure \c
        / unknown.  'unknown' means the comment had a mode line but no \c
        'is Det' suffix.\n\n\c
        Built-in / C-implemented predicates and predicates without a \c
        PlDoc source comment yield only meta_predicate (if declared) \c
        and the manual summary (if any).",
       #{ type: object,
          properties:
              #{ name:   #{ type: string },
                 arity:  #{ type: integer, minimum: 0 },
                 module: #{ type: string },
                 file:   #{ type: string,
                            description:"Absolute path to a .pl file" }
               },
          required: [name, arity]
        }).

:- meta_predicate
    sig_mode(+,:,-,-),
    sig_file(:, -),
    sig_meta(:, -),
    sig_summary(+, :, -).

pldoc_signature(Args, Text) :-
    args_pi(Args, PI),
    (   FileS = Args.get(file)
    ->  atom_string(File, FileS),
        (   exists_file(File)
        ->  true
        ;   format(string(Text), "No such file: ~w", [File]),
            !, fail
        )
    ;   ignore(sig_file(PI, File))
    ),
    (   nonvar(File)
    ->  catch(xref_source(File, [silent(true)]), error(_,_), true)
    ;   true
    ),
    findall(Mode-Det, sig_mode(File, PI, Mode, Det), Modes0),
    list_to_set(Modes0, Modes),
    sig_meta(PI, Meta),
    sig_summary(File, PI, Summary),
    with_output_to(string(Text),
                   format_signature(File, PI, Modes, Meta, Summary)).
pldoc_signature(_Args, "pldoc_signature: failed.").

sig_file(PI, File) :-
    pi_head(PI, Head),
    predicate_property(Head, file(File)),
    !.
sig_file(PI, File) :-
    dcg_pi(PI, PI2),
    pi_head(PI2, Head),
    predicate_property(Head, file(File)),
    !.

dcg_pi(M:PI, PI2) =>
    dcg_pi(PI, PI1),
    PI2 = M:PI1.
dcg_pi(Name/Arity, PI2), integer(Arity) =>
    Arity2 is Arity+2,
    PI2 = Name/Arity2.

%!  sig_mode(?File, :PI, -Mode, -Det) is nondet.
%
%   Yield mode/determinism pairs.  Matches by functor name; arity may
%   either match Arity exactly or differ by +2 (DCG: Mode is then a
%   //N form with the original arity).

sig_mode(File, _:Name/Arity, Mode, Det) :-
    nonvar(File),
    %  setof over distinct comments: pldoc indexes one comment per
    %  predicate indicator (PI), so a comment block declaring several
    %  arities for the same name surfaces once per PI from
    %  xref_comment/4.  Without setof we'd run comment_modes/2 (and
    %  emit duplicates) once per PI.
    setof(C,
          CHead^Summary^( xref_comment(File, CHead, Summary, C),
                          callable(CHead),
                          functor(CHead, Name, _)
                        ),
          Comments),
    member(Comment, Comments),
    catch(comment_modes(Comment, RawModes), error(_,_), fail),
    member(RawMode, RawModes),
    mode_with_det(RawMode, Mode, Det),
    mode_matches(Mode, Name, Arity).

mode_with_det(_:H, Mode, Det) :- !, mode_with_det(H, Mode, Det).
mode_with_det(H is Det, H, Det) :- !.
mode_with_det(H, H, unknown).

%  DCG mode lines parse via the (//)/1 postfix operator -- accept
%  matches against either the DCG source arity or the callable
%  arity after grammar expansion (+2 list args).
mode_matches(Mode, Name, Arity) :-
    Mode =.. ['//', Inner],
    !,
    functor(Inner, Name, SA),
    (   Arity =:= SA
    ;   Arity =:= SA + 2
    ).
mode_matches(Mode, Name, Arity) :-
    functor(Mode, Name, Arity).

sig_meta(PI, Spec) :-
    pi_head(PI, Head),
    predicate_property(Head, meta_predicate(Spec)),
    !.
sig_meta(_, none).

sig_summary(File, _:Name/_Arity, Summary) :-
    nonvar(File),
    xref_comment(File, CHead, S, _Comment),
    callable(CHead),
    functor(CHead, Name, _),
    !,
    Summary = S.
sig_summary(_, _:Name/Arity, Summary) :-
    catch(man_object_property(Name/Arity, summary(S)),
          error(_,_), fail),
    !,
    Summary = S.
sig_summary(_, _, none).

format_signature(File, _Module:PI, Modes, Meta, Summary) :-
    format("~q", [PI]),
    (   nonvar(File)
    ->  format(" (source: ~w)", [File])
    ;   true
    ),
    nl, nl,
    format("Modes:~n"),
    (   Modes == []
    ->  format("  (no PlDoc mode declarations)~n")
    ;   forall(member(M-D, Modes),
               (   format("  ", []),
                   write_term(M, [quoted(false),
                                  numbervars(true),
                                  spacing(next_argument),
                                  module(pldoc_modes)]),
                   format(" is ~w~n", [D])
               ))
    ),
    nl,
    format("Meta-predicate:~n"),
    (   Meta == none
    ->  format("  (none)~n")
    ;   format("  ~q~n", [Meta])
    ),
    nl,
    format("Summary:~n"),
    (   Summary == none
    ->  format("  (no summary available)~n")
    ;   format("  ~w~n", [Summary])
    ).


:- mcp_tool(
       predicate_property_summary,
       "Curated, grouped predicate_property/2 snapshot for a predicate.\n\n\c
        Filters out noisy properties (last_modified_generation, size, \c
        line_count, nodebug, ...) and groups the rest into Module, \c
        Location, Kind (built_in/static/dynamic/foreign/...), \c
        Modifiers (meta_predicate/multifile/transparent/...), and \c
        Clauses.\n\n\c
        Use predicate_info instead if you want the raw, unfiltered \c
        property list.",
       #{ type: object,
          properties:
              #{ name:   #{ type: string },
                 arity:  #{ type: integer, minimum: 0 },
                 module: #{ type: string }
               },
          required: [name, arity]
        }).

predicate_property_summary(Args, Text) :-
    args_pi(Args, PI),
    pi_head(PI, Head),
    pp_defining_module(Head),
    (   predicate_property(Head, defined)
    ->  with_output_to(string(Text), pp_summary(Head))
    ;   format(string(Text), "No such predicate: ~q", [PI])
    ).

%  Prefer the canonical defining module (where imported_from is not
%  set) over any importing context that happened to be enumerated
%  first by predicate_property/2.

pp_defining_module(M:Head) :-
    var(M),
    predicate_property(M:Head, defined),
    \+ predicate_property(M:Head, imported_from(_)),
    !.
pp_defining_module(_).

pp_summary(QHead) :-
    pi_head(PI, QHead),
    format("~q~n", [PI]),
    pp_module(QHead),
    pp_location(QHead),
    pp_kind(QHead),
    pp_modifiers(QHead),
    pp_clauses(QHead).

pp_module(QHead) :-
    QHead = Module:_,
    (   predicate_property(QHead, imported_from(Src))
    ->  format("  Module:     ~q  (imported from ~q)~n", [Module, Src])
    ;   format("  Module:     ~q~n", [Module])
    ).

pp_location(QHead) :-
    (   predicate_property(QHead, file(File))
    ->  (   predicate_property(QHead, line_count(L))
        ->  format("  Location:   ~w:~w~n", [File, L])
        ;   format("  Location:   ~w~n", [File])
        )
    ;   predicate_property(QHead, autoload(Where))
    ->  format("  Autoload:   ~w~n", [Where])
    ;   true
    ).

pp_kind(QHead) :-
    findall(K, pp_kind_flag(QHead, K), Ks),
    (   Ks == []
    ->  true
    ;   atomic_list_concat(Ks, ', ', S),
        format("  Kind:       ~w~n", [S])
    ).

pp_kind_flag(QHead, 'built-in')  :- predicate_property(QHead, built_in).
pp_kind_flag(QHead, foreign)     :- predicate_property(QHead, foreign).
pp_kind_flag(QHead, dynamic)     :- predicate_property(QHead, dynamic).
pp_kind_flag(QHead, thread_local):- predicate_property(QHead, thread_local).
pp_kind_flag(QHead, volatile)    :- predicate_property(QHead, volatile).
pp_kind_flag(QHead, tabled)      :- predicate_property(QHead, tabled).
pp_kind_flag(QHead, static)      :-
    predicate_property(QHead, static),
    \+ predicate_property(QHead, built_in),
    \+ predicate_property(QHead, foreign).
pp_kind_flag(QHead, exported)    :- predicate_property(QHead, exported).
pp_kind_flag(QHead, public)      :- predicate_property(QHead, public).
pp_kind_flag(QHead, iso)         :- predicate_property(QHead, iso).

pp_modifiers(QHead) :-
    findall(M, pp_mod(QHead, M), Mods),
    (   Mods == []
    ->  true
    ;   format("  Modifiers:~n"),
        forall(member(M, Mods), format("    - ~q~n", [M]))
    ).

pp_mod(QHead, meta_predicate(Spec)) :- predicate_property(QHead, meta_predicate(Spec)).
pp_mod(QHead, multifile)            :- predicate_property(QHead, multifile).
pp_mod(QHead, discontiguous)        :- predicate_property(QHead, discontiguous).
pp_mod(QHead, transparent)          :- predicate_property(QHead, transparent).
pp_mod(QHead, det)                  :- predicate_property(QHead, det).
pp_mod(QHead, ssu)                  :- predicate_property(QHead, ssu).
pp_mod(QHead, non_terminal)         :- predicate_property(QHead, non_terminal).

pp_clauses(QHead) :-
    (   ( predicate_property(QHead, dynamic)
        ; predicate_property(QHead, multifile)
        ),
        predicate_property(QHead, number_of_clauses(N))
    ->  format("  Clauses:    ~w~n", [N])
    ;   true
    ).


:- mcp_tool(
       file_xref,
       "Cross-reference summary of a Prolog source file: list \c
        predicates it defines, exports, imports, and which built-ins \c
        or library predicates it calls.  No side effects -- the file \c
        is xref'ed, not loaded.  Companion: file_check reports the \c
        warnings / errors xref produces (singletons, syntax errors, \c
        undefined call sites).",
       #{ type: object,
          properties:
              #{ file: #{type:string,
                         description:"Absolute path to a .pl file"} },
          required: [file]
        }).

file_xref(Args, Text) :-
    atom_string(File, Args.file),
    xref_source(File, [silent(true)]),
    findall(Def,
            ( xref_defined(File, Def, How),
              How \= imported(_) ),
            Defs0),
    sort(Defs0, Defs),
    findall(Ex, xref_exported(File, Ex), Exports0),
    sort(Exports0, Exports),
    findall(Call, xref_called(File, Call, _By), Calls0),
    sort(Calls0, Calls),
    findall(F-Spec,
            xref_uses_file(File, Spec, F),
            Uses),
    with_output_to(string(Text),
                   format_xref(File, Defs, Exports, Calls, Uses)).


:- mcp_tool(
       predicate_callers,
       "Find every place a predicate is called from inside a directory \c
        tree.  Uses prolog_xref to walk every .pl/.prolog file under \c
        the chosen subtree of a configured source root, then collects \c
        callers from xref_called/5.  Output is one line per call site: \c
          <relpath>:<line>  <caller-pi>  ->  <called-pi>. \c
        Optional arity narrows the search to one specific arity; \c
        optional module restricts to one declaring module.  Scope the \c
        walk to a sub-directory of the root via `dir`.  max_results \c
        caps the output (default 100).",
       #{ type: object,
          properties:
              #{ root:    #{ type: string,
                             description: "Source root name (see \c
                                          source_roots)" },
                 name:    #{ type: string,
                             description: "Predicate name" },
                 arity:   #{ type: integer, minimum: 0 },
                 module:  #{ type: string,
                             description: "Optional module qualifier" },
                 dir:     #{ type: string,
                             description: "Subdirectory inside root \c
                                          (default: the root itself)" },
                 max_results: #{ type: integer,
                                 minimum: 1, maximum: 5000 }
               },
          required: [root, name]
        }).

predicate_callers(Args, Text) :-
    args_pi(Args, PI),
    Max = Args.get(max_results, 100),
    args_root(Args, RootName, RootPath, SearchDir, Err),
    (   var(Err)
    ->  walk_prolog_files(SearchDir, Files),
        findall(hit(File, Line, By, Called),
                xref_caller(Files, PI,
                            File, Line, By, Called),
                Hits0),
        sort(Hits0, Hits),
        length(Hits, NTotal),
        first_n(Hits, Max, Shown),
        length(Shown, NShown),
        atom_concat(RootPath, '/', RootSlash),
        with_output_to(string(Text),
                       format_callers(RootName, PI,
                                      NShown, NTotal, RootSlash, Shown))
    ;   Text = Err
    ).
predicate_callers(_Args, "predicate_callers failed").

%!  args_root(+Args, -RootName, -RootPath, -SearchDir, -Err) is det.
%
%   Resolve the `root` (and optional `dir`) fields of the argument
%   dict to a filesystem path.  Err stays unbound on success; on
%   failure it is bound to a human-readable error string and the
%   other output args may be unbound.  Same shape as
%   mcp_server_git:git_root/4 -- the helper always succeeds so the
%   caller can decide how to surface the error in Text.

args_root(Args, RootName, RootPath, SearchDir, Err) :-
    atom_string(RootName, Args.root),
    (   source_root_path(RootName, RootPath)
    ->  (   DirS = Args.get(dir)
        ->  atom_string(Dir, DirS),
            directory_file_path(RootPath, Dir, SearchDir)
        ;   SearchDir = RootPath
        ),
        (   exists_directory(SearchDir)
        ->  true
        ;   format(string(Err),
                   "Not a directory: ~w", [SearchDir])
        )
    ;   format(string(Err), "Unknown root: ~w", [RootName])
    ).


%!  xref_caller(+Files, +PI,
%!              -File, -Line, -By, -Called) is nondet.

xref_caller(Files, PI,
            File, Line, By, Called) :-
    member(File, Files),
    xref_source(File, [silent(true)]),
    xref_called(File, Called, By, _Cond, Line),
    matches_called(Called, PI).

matches_called(Called, PI) :-
    PI = M:Name/Arity,
    (   Called = M:Head
    ->  true
    ;   Head = Called
    ),
    callable(Head),
    head_name_arity(Head, Name, Arity).

format_callers(RootName, Module:Name/Arity,
               NShown, NTotal, RootSlash, Hits) :-
    (   var(Arity)
    ->  ArityT = ' (any arity)'
    ;   format(atom(ArityT), '/~w', [Arity])
    ),
    (   var(Module)
    ->  ModT = ''
    ;   format(atom(ModT), ' in ~w', [Module])
    ),
    format("Callers of ~w~w~w in ~w (~w of ~w):~n~n",
           [Name, ArityT, ModT, RootName, NShown, NTotal]),
    forall(member(hit(File, Line, By, Called), Hits),
           (   (   atom_concat(RootSlash, Rel, File) -> true ; Rel = File ),
               print_caller_hit(Rel, Line, By, Called)
           )).

print_caller_hit(Rel, Line, By, Called) :-
    head_string(By, ByPI),
    head_string(Called, CalledPI),
    format("  ~w:~w~t~52|~w~t~78|-> ~w~n",
           [Rel, Line, ByPI, CalledPI]).

head_string(Goal, S) :-
    callable(Goal),
    pi_head(PI, Goal),
    (   PI = M:_,
        nonvar(M)
    ->  format(string(S), "~q", [PI])
    ;   PI = _:PI2
    ->  format(string(S), "~q", [PI2])
    ;   format(string(S), "~q", [PI])
    ).
head_string(Other, S) :-
    format(string(S), "~q", [Other]).


                /*******************************
                *       FILE TREE WALK         *
                *******************************/

walk_prolog_files(Dir, Files) :-
    findall(File,
            directory_member(Dir, File,
                             [ recursive(true),
                               file_type(source),
                               file_errors(fail),
                               access(read),
                               hidden(false)
                             ]),
           Files0),
    sort(Files0, Files).

:- mcp_tool(
       file_check,
       "Cross-reference a Prolog source file and report every warning \c
        or error that fires during xref: syntax errors, singleton \c
        warnings, deprecation notices, etc.  Also lists callable goals \c
        that are not defined in the file and not imported / not \c
        built-in (undefined-predicate candidates).  No side effects -- \c
        the file is xref'ed, not loaded.",
       #{ type: object,
          properties:
              #{ file: #{ type: string,
                          description: "Absolute path to a .pl file" } },
          required: [file]
        }).

file_check(Args, Text) :-
    atom_string(File, Args.file),
    (   exists_file(File)
    ->  true
    ;   format(string(Text), "No such file: ~w", [File]),
        !, fail
    ),
    %  Drop any cached xref so the term reader re-runs and
    %  the singleton / syntax messages fire under our hook.
    catch(xref_clean(File), error(_,_), true),
    run_collect_messages(
        xref_source(File, [silent(false), register_called(all)]),
        [K]>>(K \== silent),
        _Result,
        Raw),
    maplist(to_check_msg, Raw, Messages),
    findall(U,
            ( xref_called(File, Called, By, _Cond, Line),
              \+ defined_or_known(File, Called),
              U = undef(Called, By, Line)
            ),
            Undefs0),
    sort(Undefs0, Undefs),
    findall(d(Def), ( xref_defined(File, Def, How),
                      How \= imported(_) ), Defs),
    length(Defs, NDefs),
    with_output_to(string(Text),
                   format_check(File, Messages, Undefs, NDefs)).
file_check(_Args, "file_check failed").

to_check_msg(message(Term, Level, Lines), msg(Level, F/A, Body)) :-
    functor(Term, F, A),
    with_output_to(string(Body),
                   print_message_lines(current_output, '', Lines)).

defined_or_known(File, Called) :-
    %  Locally defined in this file.
    xref_defined(File, Called, _), !.
defined_or_known(_File, Called) :-
    %  Module-qualified -- assume the user knows about it.
    Called = _:_, !.
defined_or_known(_File, Called) :-
    %  Built-in / system / autoloadable in the running process.
    callable(Called),
    functor(Called, Name, Arity),
    functor(Probe, Name, Arity),
    (   catch(predicate_property(user:Probe, defined),
              error(_,_), fail)
    ;   catch(predicate_property(system:Probe, defined),
              error(_,_), fail)
    ;   catch(predicate_property(user:Probe, autoload(_)),
              error(_,_), fail)
    ),
    !.

format_check(File, Messages, Undefs, NDefs) :-
    format("Check report for ~w~n", [File]),
    format("  Defines ~w predicate(s)~n", [NDefs]),
    length(Messages, NMsg),
    length(Undefs, NUndef),
    format("  ~w message(s), ~w undefined call site(s)~n~n",
           [NMsg, NUndef]),
    (   Messages == []
    ->  format("(no messages from xref)~n", [])
    ;   format("Messages:~n", []),
        forall(member(msg(Level, Kind, Body), Messages),
               format("  [~w ~w] ~w~n", [Level, Kind, Body]))
    ),
    (   Undefs == []
    ->  format("~n(no undefined calls)~n", [])
    ;   format("~nUndefined calls:~n", []),
        forall(member(undef(Called, By, Line), Undefs),
               (   head_string(By, ByS),
                   head_string(Called, CalledS),
                   format("  line ~w: ~w -> ~w~n", [Line, ByS, CalledS])
               ))
    ).


:- mcp_tool(
       module_exports,
       "List the predicates exported by a module.  Returns one line per \c
        export -- Name/Arity, followed by a one-line summary when one \c
        is available (from the SWI manual or from a PlDoc comment in \c
        the source).  The `module` argument is either a module name \c
        (atom, e.g. 'lists') or a library spec (e.g. 'library(lists)', \c
        'library(http/json)').  Optional `pattern` filters exports by \c
        substring of the predicate name.",
       #{ type: object,
          properties:
              #{ module:  #{ type: string,
                             description: "Module name or library spec" },
                 pattern: #{ type: string,
                             description: "Substring filter on names" }
               },
          required: [module]
        }).

module_exports(Args, Text) :-
    Pat = Args.get(pattern, ""),
    catch(parse_module_spec(Args.module, FileSpec),
          error(_,_),
          ( format(string(Text), "Could not parse module spec: ~w",
                   [Args.module]),
            fail
          )),
    catch(absolute_file_name(FileSpec, File,
                             [ file_type(prolog),
                               access(read),
                               file_errors(fail)
                             ]),
          error(_,_), fail),
    !,
    xref_source(File, [silent(true), comments(store)]),
    (   xref_module(File, Module)
    ->  true
    ;   Module = '<no module>'
    ),
    findall(Head, xref_exported(File, Head), Heads0),
    sort(Heads0, Heads),
    include(matches_name(Pat), Heads, Filtered),
    maplist(export_line(File, Module), Filtered, Lines),
    length(Filtered, NShown),
    length(Heads, NTotal),
    with_output_to(string(Text),
                   format_module_exports(Module, File,
                                         NShown, NTotal, Pat, Lines)).
module_exports(Args, Text) :-
    format(string(Text), "Could not resolve module: ~w", [Args.module]).

%!  parse_module_spec(+Spec:text, -FileSpec) is det.
%
%   Accept either a bare name (lists) or a library/file-search-path
%   compound (library(http/json)).  Read it as a Prolog term so the
%   nested form survives.

parse_module_spec(SpecAtom, FileSpec) :-
    term_string(Term, SpecAtom, []),
    (   compound(Term)
    ->  FileSpec = Term
    ;   FileSpec = library(Term)
    ).

matches_name(Pat, Head), atom(Head) =>
    sub_atom(Head, _, _, _, Pat),
    !.
matches_name(Pat, Head), compound(Head) =>
    compound_name_arity(Head, Name, _),
    sub_atom(Name, _, _, _, Pat),
    !.

%!  export_line(+File, +Module, +Head, -Line) is det.

export_line(File, Module, Head, line(PI, Summary)) :-
    functor(Head, Name, Arity),
    PI = Name/Arity,
    (   summary_for(File, Module, Head, Summary)
    ->  true
    ;   Summary = ''
    ).

summary_for(File, _Module, Head, Summary) :-
    xref_comment(File, Head, SummaryRaw, _Comment),
    !,
    one_line(SummaryRaw, Summary).
summary_for(_File, _Module, Head, Summary) :-
    functor(Head, Name, Arity),
    %  The manual index keys predicates by bare Name/Arity (no module
    %  qualifier), even for ones that live in a library.
    catch(man_object_property(Name/Arity, summary(SummaryRaw)),
          error(_,_), fail),
    !,
    one_line(SummaryRaw, Summary).

one_line(In, Out) :-
    split_string(In, "\n", "", [First|_]),
    string_length(First, L),
    (   L > 80
    ->  sub_string(First, 0, 77, _, Trim),
        string_concat(Trim, "...", Out)
    ;   Out = First
    ).

format_module_exports(Module, File, NShown, NTotal, Pat, Lines) :-
    (   Pat == ""
    ->  format("Module ~w (~w): ~w exports~n~n",
               [Module, File, NTotal])
    ;   format("Module ~w (~w): ~w of ~w exports matching ~q~n~n",
               [Module, File, NShown, NTotal, Pat])
    ),
    forall(member(line(PI, Summary), Lines),
           (   Summary == ''
           ->  format("  ~q~n", [PI])
           ;   format("  ~w~t~28|~w~n", [PI, Summary])
           )).


:- mcp_tool(
       file_autoload,
       "Compute the :- autoload (or :- use_module) directives that a \c
        Prolog source file needs.  xrefs the file, finds called \c
        predicates that are not yet imported, and returns a source \c
        block ready to paste at the top of the file.  Built-ins are \c
        excluded automatically.  The `missing` option (default true) \c
        limits the result to NOT-yet-imported predicates; with `missing \c
        false` it emits the full block including imports already \c
        declared.  The `directive` option picks the flavour: \c
        'use_autoload/2' (default), 'use_autoload/1', 'use_module/2' \c
        or 'use_module/1'.",
       #{ type: object,
          properties:
              #{ file:      #{ type: string,
                               description:"Absolute path to a .pl file" },
                 missing:   #{ type: boolean,
                               description:"Only show missing imports \c
                                            (default true)" },
                 directive: #{ type: string,
                               enum: [ "use_autoload/2",
                                       "use_autoload/1",
                                       "use_module/2",
                                       "use_module/1" ],
                               description:"Default: use_autoload/2" }
               },
          required: [file]
        }).

file_autoload(Args, Text) :-
    atom_string(File, Args.file),
    Missing = Args.get(missing, true),
    (   DirS = Args.get(directive)
    ->  atom_string(DirAtom, DirS),
        parse_directive_spec(DirAtom, DirSpec),
        Options0 = [missing(Missing), directive(DirSpec)]
    ;   Options0 = [missing(Missing)]
    ),
    catch(file_autoload_directives(File, Directives, Options0),
          Error,
          ( message_to_string(Error, EMsg),
            format(string(Text), "file_autoload failed: ~w", [EMsg]),
            fail
          )),
    !,
    (   Directives == []
    ->  Text = "All called predicates are already imported.  \c
                Nothing to add."
    ;   with_output_to(string(Text),
                       render_autoload_directives(File, Directives))
    ).
file_autoload(_Args, "file_autoload failed").

parse_directive_spec('use_autoload/2', use_autoload/2) :- !.
parse_directive_spec('use_autoload/1', use_autoload/1) :- !.
parse_directive_spec('use_module/2',   use_module/2)   :- !.
parse_directive_spec('use_module/1',   use_module/1)   :- !.
parse_directive_spec(Other,            use_autoload/2) :-
    %  Unknown -- fall back to the default rather than error out.
    debug(mcp(file_autoload),
          'unknown directive spec ~q; using use_autoload/2', [Other]).

render_autoload_directives(File, Directives) :-
    format("Suggested directives for ~w:~n~n", [File]),
    forall(member(D, Directives),
           portray_clause(D)).

format_xref(File, Defs, Exports, Calls, Uses) :-
    length(Exports, NE),
    length(Defs, ND),
    length(Calls, NC),
    length(Uses, NU),
    format("File: ~w~n~n", [File]),
    format("Exports (~d):~n", [NE]),
    forall(member(E, Exports), format("  ~q~n", [E])),
    nl,
    format("Defines (~d):~n", [ND]),
    forall(member(D, Defs), format("  ~q~n", [D])),
    nl,
    format("Calls (~d):~n", [NC]),
    forall(member(C, Calls), format("  ~q~n", [C])),
    nl,
    format("Uses files (~d):~n", [NU]),
    forall(member(F-Spec, Uses), format("  ~q (~w)~n", [Spec, F])).


:- mcp_tool(
       pack_info,
       "Return metadata for an installed SWI-Prolog pack.",
       #{ type: object,
          properties: #{ pack: #{type:string} },
          required: [pack]
        }).

pack_info(Args, Text) :-
    atom_string(Pack, Args.pack),
    findall(P, pack_property(Pack, P), Props),
    (   Props == []
    ->  format(string(Text), "Unknown pack: ~w", [Pack])
    ;   with_output_to(string(Text), format_props(Pack, Props))
    ).


:- mcp_tool(
       locate_source,
       "Find the source location(s) of a predicate.  Returns file (and \c
        line when known) for Prolog clauses, autoloaded library entries, \c
        and -- when the swipl binary has debug symbols -- the C source \c
        of built-ins via addr2line.  Arity is optional; without it, \c
        every matching arity is reported.  Module is optional; with it, \c
        only that module is considered.",
       #{ type: object,
          properties:
              #{ name:   #{type:string, description:"Predicate name"},
                 arity:  #{type:integer, minimum:0,
                           description:"Optional predicate arity"},
                 module: #{type:string,
                           description:"Optional module qualifier"}
               },
          required: [name]
        }).

locate_source(Args, Text) :-
    atom_string(Name, Args.name),
    (   Arity = Args.get(arity)
    ->  Spec0 = Name/Arity
    ;   Spec0 = Name/_
    ),
    (   ModuleS = Args.get(module)
    ->  atom_string(Module, ModuleS),
        Spec = Module:Spec0
    ;   Spec = Spec0
    ),
    prolog_edit:locations(Spec, Pairs),
    (   Pairs == []
    ->  format(string(Text), "No source location for ~q", [Spec])
    ;   with_output_to(string(Text),
                       maplist(format_loc, Pairs))
    ).

format_loc(Loc-FullSpec) =>
    File = Loc.file,
    (   Line = Loc.get(line)
    ->  format("~w:~w  ~q~n", [File, Line, FullSpec])
    ;   format("~w  ~q~n", [File, FullSpec])
    ).

:- mcp_tool(
       explain,
       "Run library(explain)'s explain/1 over a term and return the \c
        system's full picture: what kind of object it is, every \c
        predicate definition matching it (with file/line and one-line \c
        summary), and -- uniquely -- the cross-references, i.e. which \c
        clauses elsewhere in the currently loaded code call it.  The \c
        term parameter is parsed as a Prolog term (e.g. 'append/3', \c
        'lists:member(_,_)', 'format', 42). \c
        max_references caps the number of reported call sites (default 20).",
       #{ type: object,
          properties:
              #{ term:
                   #{type:string,
                     description:"Prolog term to explain"},
                 max_references:
                   #{type:integer, minimum:0, maximum:1000,
                     description:"Cap on references (default 20)"}
               },
          required: [term]
        }).

explain(Args, Text) :-
    TermString = Args.term,
    Error = error(_,_),
    catch(term_string(Term, TermString), Error,
          ( message_to_string(Error, EMsg),
            format(string(Text), "Could not parse term: ~w", [EMsg]),
            fail
          )),
    !,
    findall(Explanation, imp_explain(Term, Explanation), Explanations),
    (   Explanations == []
    ->  format(string(Text), "No explanation for ~w", [TermString])
    ;   MaxRefs = Args.get(max_references, 20),
        limit_references(MaxRefs, Explanations, Explanations1, 0, Skipped),
        maplist(explanation_line, Explanations1, Lines),
        (   Skipped == 0
        ->  Lines1 = Lines
        ;   (   MaxRefs == 0
            ->  More = ""
            ;   More = " more"
            ),
            format(string(SkippedLine),
                   "Suppressed ~d~w references", [Skipped, More]),
            append(Lines, [SkippedLine], Lines1)
        ),
        atomics_to_string(Lines1, "\n", Text)
    ).
explain(_Args, "Could not parse term").

limit_references(_, [], [], S, S) :-
    !.
limit_references(0, [H|T0], T, S0, S) :-
    is_ref(H),
    !,
    S1 is S0+1,
    limit_references(0, T0, T, S1, S).
limit_references(N, [H|T0], [H|T], S0, S) :-
    is_ref(H),
    !,
    N1 is N - 1,
    limit_references(N1, T0, T, S0, S).
limit_references(N, [H|T0], [H|T], S0, S) :-
    limit_references(N, T0, T, S0, S).

is_ref(E) :-
    memberchk(_-['Referenced'|_], E).



explanation_line(Explanation, Line) :-
    message_to_string(explain(Explanation), Line).

:- mcp_tool(
       manual_section,
       "Return the body of a SWI-Prolog manual section by anchor (e.g. \c
        'sec:unicodesyntax' or 'unicodesyntax').  Use apropos to discover \c
        anchors; they appear as the third argument of section(...) entries.",
       #{ type: object,
          properties:
              #{ id: #{type:string,
                       description:"Section anchor, e.g. sec:unicodesyntax"} },
          required: [id]
        }).

manual_section(Args, Text) :-
    atom_string(IDIn, Args.id),
    section_label(IDIn, Label),
    (   man_object_property(section(_L,_N,Label,_F), id(_))
    ->  render_section(Label, Text)
    ;   format(string(Text), "No manual section with anchor ~w", [Label])
    ).

section_label(In, Out) :-
    (   sub_atom(In, 0, 4, _, 'sec:')
    ->  Out = In
    ;   atom_concat('sec:', In, Out)
    ).

render_section(Label, Text) :-
    Spec = section(Label),
    phrase(html(html([ head([]),
                       body([ dl(\man_page(Spec,
                                           [ no_manual(fail),
                                             links(false),
                                             link_source(false),
                                             navtree(false),
                                             server(false),
                                             qualified(always)
                                           ])) ])
                     ])),
           Tokens),
    !,
    with_output_to(string(HTML), print_html(Tokens)),
    setup_call_cleanup(
        open_string(HTML, In),
        load_html(stream(In), DOM, []),
        close(In)),
    with_output_to(string(Text), html_text(DOM, [width(80)])).
render_section(Label, Text) :-
    format(string(Text), "Failed to render manual section ~w", [Label]).


                /*******************************
                *         RESOURCES            *
                *******************************/

:- mcp_resource_template(
       "prolog://help/{name}/{arity}",
       "SWI-Prolog manual entry as a resource.",
       [ name("Predicate manual entry"),
         mime_type("text/plain"),
         handler(resource_predicate_help)
       ]).

resource_predicate_help(_URI, Bindings, Text) :-
    NameS = Bindings.name,
    ArityS = Bindings.arity,
    atom_string(Name, NameS),
    number_string(Arity, ArityS),
    (   help_text(Name/Arity, Text)
    ->  true
    ;   format(string(Text), "No manual entry for ~w/~w", [Name, Arity])
    ).

:- mcp_resource_template(
       "prolog://section/{id}",
       "SWI-Prolog manual section body as a resource.",
       [ name("Manual section"),
         mime_type("text/plain"),
         handler(resource_manual_section)
       ]).

resource_manual_section(_URI, Bindings, Text) :-
    atom_string(IDIn, Bindings.id),
    section_label(IDIn, Label),
    (   man_object_property(section(_L,_N,Label,_F), id(_))
    ->  render_section(Label, Text)
    ;   format(string(Text), "No manual section with anchor ~w", [Label])
    ).
