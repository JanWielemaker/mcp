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

:- module(mcp_target,
          [ mcp_emit/1,                 % +Dict
            mcp_profile/2,              % :Goal, +Top
            mcp_profile_node/2,         % +PredSpec, +Top
            mcp_coverage/3,             % :Goal, +Top, +Roots
            mcp_coverage_file/2         % +FileSpec, +Top
          ]).
:- use_module(library(json), [json_write_dict/3]).
:- use_module(library(apply), [maplist/2, maplist/3, include/3]).
:- use_module(library(lists), [member/2, append/3]).

/** <module> Child-side instrumentation for the MCP target toplevel

This file is loaded into the child swipl with -l.  It wraps the
standard toplevel's output with magic markers so the parent proxy
can demultiplex events (messages, prompts) from plain stdout.

Wire format:

  - Plain user-program output: passed through verbatim.
  - Structured events: framed as

        <SOH = 0x01> <JSON-object-as-one-line> <ETX = 0x03>

    where the JSON has at minimum a `k` field naming the event kind.

Event kinds in this MVP:

  - k=message     A print_message/2 call.  Fields: level, kind, text.
  - k=prompt      The toplevel is about to block on a read.  Fields:
                  kind ("toplevel"), prompt (rendered prompt text).
*/

:- multifile user:message_hook/3.

%!  user:message_hook(+Term, +Level, +Lines) is semidet.
%
%   Wrap every print_message call's output in a magic event and
%   return true to suppress the default printer.  Falls back to
%   default (by failing) for `silent` level or when our emitter
%   raises an exception.

user:message_hook(_, silent, _) :- !, fail.
user:message_hook(Term, Level, Lines) :-
    catch(emit_message(Term, Level, Lines), error(_,_), fail).

emit_message(Term, Level, Lines) :-
    with_output_to(string(Text),
                   print_message_lines(current_output, '', Lines)),
    (   compound(Term)
    ->  functor(Term, F, A),
        format(atom(Kind), "~w/~w", [F, A])
    ;   Kind = Term
    ),
    mcp_emit(#{k:message, level:Level, kind:Kind, text:Text}).

%!  mcp_emit(+Dict) is det.
%
%   Serialise Dict as a single-line JSON object framed by SOH/ETX
%   markers on user_output.  Holds a mutex so events from different
%   threads do not interleave.

mcp_emit(Dict) :-
    with_mutex(mcp_emit, mcp_emit_unlocked(Dict)).

mcp_emit_unlocked(Dict) :-
    with_output_to(string(JSON),
                   json_write_dict(current_output, Dict, [width(0)])),
    format(user_output, "\x01\~w\x03\", [JSON]),
    flush_output(user_output).


                /*******************************
                *           PROMPTS            *
                *******************************/

%  Build the toplevel_prompt flag value to include a magic prompt
%  event before the visible prompt text.  Format specifiers ~m, ~l,
%  ~d are processed by '$system_prompt'/3 in boot/toplevel.pl after
%  we've installed the flag.

install_toplevel_prompt :-
    magic_prompt(toplevel, Prompt),
    set_prolog_flag(toplevel_prompt, Prompt).

%!  install_read_prompt is det.
%
%   Set the default prompt on user_input to a magic prompt event
%   with kind:read.  Every read_term/read that does not set its
%   own prompt via prompt1/1 inherits this; user-code calls to
%   read/1 etc.  therefore announce themselves to the proxy.

install_read_prompt :-
    magic_prompt(read, Prompt),
    prompt(_Old, Prompt).

magic_prompt(Kind, Prompt) :-
    atom_codes(MagicHead, [0x01]),
    atom_codes(MagicTail, [0x03]),
    format(atom(Prompt),
           "~w{\"k\":\"prompt\",\"kind\":\"~w\"}~w",
           [MagicHead, Kind, MagicTail]).


                /*******************************
                *      TRACE INTERCEPTION      *
                *******************************/

%!  user:prolog_trace_interception(+Port, +Frame, +Choice, -Action).
%
%   Fires for every port the debugger visits when tracing is on.
%   Emits a `trace` event with the port, the frame goal, and the
%   frame depth, then a `prompt(kind:trace)` event and blocks on
%   user_input for the next debugger command.  The proxy is expected
%   to send a single short command (creep, skip, leap, fail, retry,
%   abort, nodebug); anything else defaults to "creep" (continue
%   to the next port).

:- multifile user:prolog_trace_interception/4.

user:prolog_trace_interception(Port, Frame, _Choice, Action) :-
    catch(do_trace(Port, Frame, Action), error(_,_), Action = continue).

do_trace(Port, Frame, Action) :-
    prolog_frame_attribute(Frame, goal, Goal),
    prolog_frame_attribute(Frame, level, Depth),
    with_output_to(string(GoalStr),
                   write_term(Goal,
                              [ quoted(true),
                                max_depth(40),
                                numbervars(true)
                              ])),
    mcp_emit(#{k:trace, port:Port, goal:GoalStr, depth:Depth}),
    mcp_emit(#{k:prompt, kind:trace}),
    read_debug_command(Line),
    debug_action(Line, Action).

read_debug_command(Line) :-
    read_string(user_input, "\n", "", _, Line).

debug_action(Line, Action) :-
    string_lower(Line, Lower),
    string_codes(Lower, Codes),
    %  Look at the first non-space char.
    skip_leading_space(Codes, [First|_]),
    !,
    char_action(First, Action).
debug_action(_, continue).

skip_leading_space([0' |T], R)  :- !, skip_leading_space(T, R).
skip_leading_space([0'\t|T], R) :- !, skip_leading_space(T, R).
skip_leading_space(X, X).

char_action(0'c, continue) :- !.   % creep
char_action(0' , continue) :- !.   % space = creep
char_action(0'\n, continue) :- !.  % bare newline = creep
char_action(0's, skip)     :- !.
char_action(0'l, nodebug)  :- !.   % leap
char_action(0'f, fail)     :- !.
char_action(0'r, retry)    :- !.
char_action(0'a, abort)    :- !.
char_action(0'n, nodebug)  :- !.
char_action(0'i, ignore)   :- !.   % ignore
char_action(0'u, up)       :- !.
char_action(_,   continue).        % unknown = creep


                /*******************************
                *           SETUP              *
                *******************************/

setup :-
    install_toplevel_prompt,
    install_read_prompt,
    %  Force UTF-8 on all three standard streams.  The proxy reads
    %  Out/Err as UTF-8 too; SOH/ETX are ASCII codepoints so the
    %  markers survive untouched while non-ASCII text in events and
    %  in plain output round-trips through library(json) and through
    %  read_string/5 on the proxy side without mojibake.
    set_stream(user_input,  encoding(utf8)),
    set_stream(user_output, encoding(utf8)),
    set_stream(user_error,  encoding(utf8)),
    %  Line-buffer user_output and user_error so the proxy sees
    %  events promptly even when the child is writing to a pipe
    %  (default block buffering would delay output until the
    %  buffer fills).
    set_stream(user_output, buffer(line)),
    set_stream(user_error,  buffer(line)),
    %  Force the input stream to behave like a tty so the standard
    %  prompt-printing path fires even when stdin is a pipe from
    %  the parent proxy.
    set_stream(user_input, tty(true)),
    %  Disable ANSI colouring; we don't want escape sequences mixing
    %  with magic markers.
    set_prolog_flag(color_term, false).

:- initialization(setup, now).


                /*******************************
                *           PROFILE            *
                *******************************/

:- meta_predicate
    mcp_profile(0, +).

%!  mcp_profile(:Goal, +Top) is det.
%
%   Run Goal under the profiler, store profile_data/1 in a global,
%   and emit a summary event listing the top N predicates by self
%   ticks.  Designed to be invoked by the MCP proxy via the toplevel.

mcp_profile(Goal, Top) :-
    profile(Goal),
    profile_data(Data),
    nb_setval(mcp_profile_data, Data),
    Summary = Data.summary,
    Nodes   = Data.nodes,
    sort_nodes(Nodes, ticks_self, Sorted),
    first_n(Sorted, Top, TopNodes),
    maplist(node_summary_dict, TopNodes, TopDicts),
    summary_dict(Summary, SummaryDict),
    mcp_emit(#{k:profile_summary,
               summary:SummaryDict,
               top:TopDicts}).

%!  mcp_profile_node(+PredSpec, +Top) is det.
%
%   Look up PredSpec (Name/Arity or Module:Name/Arity, as atom) in
%   the most recently stored profile data and emit the callers and
%   callees with their relative ticks.

mcp_profile_node(PredSpec, Top) :-
    (   nb_current(mcp_profile_data, Data)
    ->  true
    ;   throw(error(existence_error(profile_data, no_profile_yet), _))
    ),
    Nodes = Data.nodes,
    (   match_node(PredSpec, Nodes, Node)
    ->  node_drill_dict(Node, Top, Drill),
        mcp_emit(#{k:profile_node, node:Drill})
    ;   format(atom(Msg),
               "No profile node matches ~w", [PredSpec]),
        mcp_emit(#{k:profile_node, error:Msg})
    ).


                /*******************************
                *         CONVERSIONS          *
                *******************************/

summary_dict(S, #{accounting:S.accounting,
                  nodes:S.nodes,
                  samples:S.samples,
                  ticks:S.ticks,
                  time:S.time}).

node_summary_dict(N, #{predicate:PStr,
                       call:N.call, exit:N.exit, redo:N.redo,
                       ticks_self:N.ticks_self,
                       ticks_siblings:N.ticks_siblings}) :-
    format(string(PStr), "~q", [N.predicate]).

node_drill_dict(N, Top, #{predicate:PStr,
                          call:N.call, exit:N.exit, redo:N.redo,
                          ticks_self:N.ticks_self,
                          ticks_siblings:N.ticks_siblings,
                          callers:CrDicts,
                          callees:CeDicts}) :-
    format(string(PStr), "~q", [N.predicate]),
    sort_relatives(N.callers, CrsSorted),
    sort_relatives(N.callees, CesSorted),
    first_n(CrsSorted, Top, CrsTop),
    first_n(CesSorted, Top, CesTop),
    maplist(relative_dict, CrsTop, CrDicts),
    maplist(relative_dict, CesTop, CeDicts).

relative_dict(node(Pred, _Cycle, TS, TSib, Calls, Redos, Exits),
              #{predicate:PStr,
                ticks_self:TS, ticks_siblings:TSib,
                call:Calls, redo:Redos, exit:Exits}) :-
    format(string(PStr), "~q", [Pred]).


                /*******************************
                *           SORTING            *
                *******************************/

sort_nodes(Nodes, ticks_self, Sorted) :-
    map_list_to_pairs(get_ticks_self, Nodes, Pairs),
    sort(1, @>=, Pairs, SortedPairs),
    pairs_values(SortedPairs, Sorted).

get_ticks_self(N, K) :- K = N.ticks_self.

sort_relatives(Rels, Sorted) :-
    map_list_to_pairs(rel_ticks, Rels, Pairs),
    sort(1, @>=, Pairs, SortedPairs),
    pairs_values(SortedPairs, Sorted).

rel_ticks(node(_, _, TS, TSib, _, _, _), Key) :-
    Key is TS + TSib.

map_list_to_pairs(_, [], []).
map_list_to_pairs(F, [H|T], [K-H|R]) :-
    call(F, H, K),
    map_list_to_pairs(F, T, R).

pairs_values([], []).
pairs_values([_-V|T0], [V|T]) :- pairs_values(T0, T).

first_n(_, 0, []) :- !.
first_n([], _, []) :- !.
first_n([H|T0], N, [H|T]) :-
    N1 is N - 1,
    first_n(T0, N1, T).


                /*******************************
                *       NODE MATCHING          *
                *******************************/

%!  match_node(+Spec:atom, +Nodes, -Node) is semidet.
%
%   Spec is the textual form of a predicate indicator (with or
%   without module qualifier), e.g. 'borders/2' or 'chat80:borders/2'.

match_node(SpecAtom, Nodes, Node) :-
    parse_predicate_spec(SpecAtom, ModuleOrAny, Name, Arity),
    member(Node, Nodes),
    node_matches(Node, ModuleOrAny, Name, Arity),
    !.

parse_predicate_spec(Spec, Module, Name, Arity) :-
    atom_codes(Spec, Codes),
    (   append(MCodes, [0':|Rest], Codes)
    ->  atom_codes(Module, MCodes),
        atom_codes(NA, Rest)
    ;   Module = '*',
        NA = Spec
    ),
    atomic_list_concat([NAtom, AAtom], '/', NA),
    atom_string(NAtom, _),
    atom_number(AAtom, Arity),
    Name = NAtom.

node_matches(Node, ModuleOrAny, Name, Arity) :-
    Pred = Node.predicate,
    (   Pred = M:Name/Arity
    ->  true
    ;   Pred = Name/Arity, M = '<any>'
    ),
    (   ModuleOrAny == '*'
    ->  true
    ;   ModuleOrAny == M
    ).


                /*******************************
                *           COVERAGE           *
                *******************************/

:- meta_predicate
    mcp_coverage(0, +, +).

%!  mcp_coverage(:Goal, +Top, +Roots) is det.
%
%   Run Goal under library(prolog_coverage), cache the full
%   (Succeeded, Failed) clause-reference lists in nb_setval, and
%   emit a coverage_summary event with per-file stats for the top
%   N files (sorted by number of uncovered clauses, descending).
%
%   Roots is a list of directory paths (atoms or strings) used to
%   filter which files appear in the summary.  Empty list disables
%   filtering and shows every file involved in the workload.  The
%   cache always contains the full data so a subsequent
%   mcp_coverage_file/2 call can drill into any file regardless of
%   the roots filter.

mcp_coverage(Goal, Top, Roots) :-
    use_module(library(prolog_coverage),
               [coverage/1, covered/2]),
    coverage(Goal),
    covered(Succeeded, Failed),
    nb_setval(mcp_coverage_data, sf(Succeeded, Failed)),
    cov_files(Succeeded, Failed, Files),
    resolve_roots(Roots, ResolvedRoots),
    include(under_roots(ResolvedRoots), Files, FilteredFiles),
    maplist(file_summary_dict(Succeeded, Failed),
            FilteredFiles, Summaries),
    sort_summaries(Summaries, Sorted),
    first_n(Sorted, Top, TopFiles),
    length(FilteredFiles, NumFiles),
    mcp_emit(#{k:coverage_summary,
               files:TopFiles,
               total_files:NumFiles}).

%!  resolve_roots(+Roots, -Canonical) is det.
%
%   Each entry in Roots may be an atom or string.  We resolve it via
%   absolute_file_name/3 with file_type(directory) so file-search-path
%   aliases work.  Returns the list of canonical directory paths each
%   ending with a slash, suitable for prefix matching.

resolve_roots([], []) :- !.
resolve_roots(Roots, Canonical) :-
    findall(P,
            ( member(R, Roots),
              ( atom(R) -> R0 = R ; atom_string(R0, R) ),
              catch(absolute_file_name(R0, P0,
                                       [ file_type(directory),
                                         solutions(all),
                                         file_errors(fail)
                                       ]), error(_,_), fail),
              ensure_trailing_slash(P0, P)
            ),
            Canonical).

ensure_trailing_slash(P, P) :-
    sub_atom(P, _, 1, 0, '/'), !.
ensure_trailing_slash(P, Q) :-
    atom_concat(P, '/', Q).

under_roots([], _).                     % no filter -> keep everything
under_roots(Roots, File) :-
    member(Root, Roots),
    atom_concat(Root, _, File),
    !.

%!  mcp_coverage_file(+FileSpec, +Top) is det.
%
%   Drill into the cached coverage data for one file.  FileSpec is a
%   string -- either an absolute path or a substring suffix that
%   uniquely matches one of the files in the cached data.

mcp_coverage_file(FileSpec, Top) :-
    (   nb_current(mcp_coverage_data, sf(Succeeded, Failed))
    ->  true
    ;   throw(error(existence_error(coverage_data, no_coverage_yet), _))
    ),
    cov_files(Succeeded, Failed, Files),
    (   match_file(FileSpec, Files, File)
    ->  file_drill_dict(File, Succeeded, Failed, Top, Drill),
        mcp_emit(#{k:coverage_file, file:Drill})
    ;   format(atom(Msg),
               "No file in cached coverage matches ~w", [FileSpec]),
        mcp_emit(#{k:coverage_file, error:Msg})
    ).


                /*******************************
                *      COVERAGE INTERNALS      *
                *******************************/

cov_files(Succeeded, Failed, Files) :-
    append(Succeeded, Failed, All),
    findall(F, (member(Cl, All), clause_property(Cl, file(F))), Fs0),
    sort(Fs0, Files).

file_summary_dict(Succeeded, Failed, File,
                  #{file:FileS,
                    total:Total,
                    covered:Covered,
                    failed:Failed_n,
                    uncovered:Uncovered_n,
                    pct_covered:Pct}) :-
    prolog_coverage:cov_clause_sets(File, Succeeded, Failed, Sets),
    length(Sets.clauses, Total),
    length(Sets.succeeded, Covered),
    length(Sets.failed, Failed_n),
    length(Sets.uncovered, Uncovered_n),
    (   Total > 0
    ->  Pct is round((Covered * 1000)/Total)/10
    ;   Pct = 0.0
    ),
    atom_string(File, FileS).

sort_summaries(In, Out) :-
    map_list_to_pairs(neg_uncovered, In, Pairs),
    sort(1, @=<, Pairs, Sorted),
    pairs_values(Sorted, Out).

neg_uncovered(Dict, K) :-
    K is -Dict.uncovered.

file_drill_dict(File, Succeeded, Failed, Top,
                #{file:FileS,
                  total:Total, covered:Covered,
                  failed:Failed_n, uncovered:Uncovered_n,
                  clauses:Clauses}) :-
    prolog_coverage:cov_clause_sets(File, Succeeded, Failed, Sets),
    length(Sets.clauses, Total),
    length(Sets.succeeded, Covered),
    length(Sets.failed, Failed_n),
    length(Sets.uncovered, Uncovered_n),
    atom_string(File, FileS),
    %  Show uncovered first (most actionable), then failed, then a
    %  sample of covered for context.
    first_n(Sets.uncovered, Top, U),
    first_n(Sets.failed, Top, F),
    first_n(Sets.succeeded, Top, C),
    maplist(clause_dict(uncovered), U, UD),
    maplist(clause_dict(failed), F, FD),
    maplist(clause_dict(covered), C, CD),
    append([UD, FD, CD], Clauses).

clause_dict(Status, ClRef,
            #{status:Status, pi:PIS, line:Line, enter:Enter, exit:Exit}) :-
    clause_property(ClRef, file(_)),         % defensive
    clause_property(ClRef, line_count(Line)),
    prolog_coverage:clause_pi(ClRef, PI),
    format(string(PIS), "~q", [PI]),
    (   catch('$cov_data'(clause(ClRef), Enter, Exit), error(_,_), fail)
    ->  true
    ;   Enter = 0, Exit = 0
    ).


                /*******************************
                *       FILE MATCHING          *
                *******************************/

match_file(SpecS, Files, File) :-
    atom_string(SpecA, SpecS),
    (   member(File, Files), File == SpecA
    ->  true
    ;   findall(F, ( member(F, Files), sub_atom(F, _, _, 0, SpecA) ), Suffix),
        (   Suffix = [File]
        ->  true
        ;   findall(F, ( member(F, Files),
                         file_base_name(F, B),
                         B == SpecA ), Bases),
            Bases = [File]
        )
    ).
