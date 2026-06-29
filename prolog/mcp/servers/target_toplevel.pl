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

:- module(mcp_server_target_toplevel, []).
:- use_module(library(mcp/server)).
:- use_module(library(mcp/target_toplevel/parser), [drain_until_prompt/3]).
:- use_module(library(process),
              [process_create/3, process_wait/2, process_kill/2]).
:- use_module(library(lists), [append/3, member/2]).
:- use_module(library(apply), [exclude/3, maplist/3]).
:- use_module(library(filesex), [directory_file_path/3]).

/** <module> MCP tools that drive a real SWI toplevel as the target

The child is a normal `swipl` started with the small `mcp_target.pl`
instrumentation file.  The proxy sends goals to the child's stdin and
reads back events demultiplexed from the magic-marker stream.

Tools registered:

  - target_start    spawn a child swipl, optionally loading files
  - target_stop     terminate the child
  - target_status   list running targets
  - target_send     send a Prolog goal (or any toplevel directive)
                    to the child and return the events until the
                    next prompt
  - target_load     reload Prolog source in the child (consult or
                    make/0)
  - target_check    run library(check) consistency checks in the
                    target -- check/0 by default, or a selected
                    subset of list_undefined / list_redefined / ...
  - target_input    send raw text (used when the child is awaiting
                    interactive input)

A target is identified by a string name (default "default").
*/

:- dynamic
    target_proc/5.                  % target_proc(Name, PID, Stdin, Stdout, Stderr)


                /*******************************
                *           TOOLS              *
                *******************************/

:- mcp_tool(
       target_start,
       "Spawn a child swipl process loaded with the MCP instrumentation \c
        file and the given user files.  Drains the startup events (banner \c
        plus first prompt) before returning.",
       #{ type: object,
          properties:
              #{ files:  #{type: array,
                           items: #{type:string},
                           description:"Files to load on startup"},
                 target: #{type:string,
                           description:"Target name (default 'default')"}
               }
        }).

target_start(Args, Text) :-
    target_name(Args, Name),
    (   target_proc(Name, _, _, _, _)
    ->  format(string(Text), "Target ~w already running", [Name])
    ;   (   Files0 = Args.get(files)
        ->  maplist(atom_string, Files, Files0)
        ;   Files = []
        ),
        launch_target(Name, Files, Text)
    ).


:- mcp_tool(
       target_stop,
       "Terminate the target process.",
       #{ type: object,
          properties:
              #{ target: #{type:string,
                           description:"Target name (default 'default')"} }
        }).

target_stop(Args, Text) :-
    target_name(Args, Name),
    (   target_proc(Name, PID, In, Out, Err)
    ->  close(In,  [force(true)]),
        close(Out, [force(true)]),
        close(Err, [force(true)]),
        catch(process_kill(PID, term), error(_,_), true),
        catch(process_wait(PID, Status), error(_,_), Status = unknown),
        retractall(target_proc(Name, _, _, _, _)),
        format(string(Text), "Target ~w stopped: ~w", [Name, Status])
    ;   format(string(Text), "No running target named ~w", [Name])
    ).


:- mcp_tool(
       target_status,
       "List the running targets -- one line per target as `name  pid=N`. \c
        Returns 'No targets running.' if none have been started.",
       #{ type: object, properties: #{} }).

target_status(_Args, Text) :-
    findall(line(N, P), target_proc(N, P, _, _, _), Lines),
    (   Lines == []
    ->  Text = "No targets running."
    ;   with_output_to(string(Text),
                       forall(member(line(N,P), Lines),
                              format("  ~w  pid=~w~n", [N, P])))
    ).


:- mcp_tool(
       target_send,
       "Send a Prolog goal (or any toplevel directive) to the target and \c
        read the response up to the next prompt.  The goal should NOT \c
        include a trailing period -- one is added.  Optional timeout in \c
        seconds (default 10).",
       #{ type: object,
          properties:
              #{ goal:    #{type:string,
                            description:"Prolog goal source"},
                 target:  #{type:string,
                            description:"Target name (default 'default')"},
                 timeout: #{type:number, minimum:0.1, maximum:300,
                            description:"Wall-clock timeout in seconds"}
               },
          required: [goal]
        }).

target_send(Args, Text) :-
    target_name(Args, Name),
    Timeout = Args.get(timeout, 10),
    atom_string(GoalA, Args.goal),
    target_run(Name, "~w .~n", [GoalA], Timeout, Text).


:- mcp_tool(
       target_load,
       "Reload Prolog source in the running target.  With `file`, runs \c
        consult(File).  Without `file`, runs make/0 (reloads every file \c
        that has changed on disk).  Returns whatever the target prints \c
        during the reload, including singleton warnings, errors and \c
        deprecation notices.",
       #{ type: object,
          properties:
              #{ file:   #{type:string,
                           description:"Optional file to consult"},
                 target: #{type:string,
                           description:"Target name (default 'default')"},
                 timeout: #{type:number, minimum:0.1, maximum:300,
                            description:"Wall-clock timeout in seconds"}
               }
        }).

target_load(Args, Text) :-
    target_name(Args, Name),
    Timeout = Args.get(timeout, 10),
    (   FileS = Args.get(file)
    ->  atom_string(File, FileS),
        format(atom(Goal), "consult(~q)", [File])
    ;   Goal = make
    ),
    target_run(Name, "~w .~n", [Goal], Timeout, Text).


:- mcp_tool(
       target_check,
       "Run library(check)'s consistency checks in the target.  The \c
        default goal is check/0, which sweeps the loaded program for \c
        undefined predicates, redefined system predicates, void \c
        declarations (declared dynamic/multifile with no clauses), \c
        trivial-failure goals, format/2-3 calls whose argument count \c
        doesn't match the format string, string objects in code, and \c
        predicates that still need autoloading.  Use this after \c
        target_load to validate the freshly loaded program.\n\n\c
        Pass `checks` to run a subset instead -- a list whose entries \c
        are the names of specific check predicates (e.g. \c
        list_undefined, list_format_errors).  The selected checks are \c
        run in the order given.",
       #{ type: object,
          properties:
              #{ checks:
                   #{ type: array,
                      items:
                        #{ type: string,
                           enum: [ "list_undefined",
                                   "list_autoload",
                                   "list_redefined",
                                   "list_cross_module_calls",
                                   "list_void_declarations",
                                   "list_trivial_fails",
                                   "list_format_errors",
                                   "list_strings",
                                   "list_rationals"
                                 ]},
                      description:"Specific checkers to run; default is \c
                                   check/0 (the comprehensive sweep)"
                    },
                 target:
                   #{type:string,
                     description:"Target name (default 'default')"},
                 timeout:
                   #{type:number, minimum:0.1, maximum:600,
                     description:"Wall-clock timeout (default 60s)"}
               }
        }).

target_check(Args, Text) :-
    target_name(Args, Name),
    Timeout = Args.get(timeout, 60),
    check_goal(Args, Goal),
    target_run(Name, "~w .~n", [Goal], Timeout, Text).

%  Build the toplevel goal to send.  An empty / absent `checks` list
%  means run check/0 (the comprehensive sweep).  A non-empty list
%  becomes a conjunction of the requested check predicates.

check_goal(Args, Goal) :-
    Checks = Args.get(checks, []),
    (   Checks == []
    ->  Goal = 'check:check'
    ;   maplist(qualified_check, Checks, Qualified),
        atomics_to_string(Qualified, ', ', Goal)
    ).

qualified_check(Atom, Q) :-
    atomics_to_string([check, Atom], :, Q).


:- mcp_tool(
       target_profile,
       "Run the SWI-Prolog profiler in the target and return the data as \c
        a structured summary, or drill into one predicate's call tree. \c
        With `goal`, runs profile(Goal) and returns the top-N predicates \c
        by self ticks (data is also stashed in the target so follow-up \c
        drill-ins do not need to re-run).  With `node`, returns the \c
        callers and callees of that predicate from the most recently \c
        stored profile (Name/Arity or Module:Name/Arity).  Supplying \c
        both re-profiles and drills in one call.",
       #{ type: object,
          properties:
              #{ goal:   #{type:string,
                           description:"Prolog goal to profile (omit to \c
                                        drill into the existing profile)"},
                 node:   #{type:string,
                           description:"Predicate indicator to drill into \c
                                        (e.g.  'chat80:borders/2')"},
                 top:    #{type:integer, minimum:1, maximum:200,
                           description:"Cap on rows / relatives (default 25)"},
                 target: #{type:string,
                           description:"Target name (default 'default')"},
                 timeout: #{type:number, minimum:0.1, maximum:300}
               }
        }).

target_profile(Args, Text) :-
    target_name(Args, Name),
    Timeout = Args.get(timeout, 60),
    Top     = Args.get(top, 25),
    (   target_proc(Name, _, In, Out, Err)
    ->  target_profile_dispatch(Args, In, Out, Err, Top, Timeout, Text)
    ;   format(string(Text), "No running target named ~w", [Name])
    ).

target_profile_dispatch(Args, In, Out, Err, Top, Timeout, Text) :-
    GoalGiven = Args.get(goal, ""),
    NodeGiven = Args.get(node, ""),
    (   GoalGiven \== "", NodeGiven \== ""
    ->  send_profile_goal(In, GoalGiven, Top),
        drain_events_until_prompt(Out, Timeout, EventsA),
        send_profile_node(In, NodeGiven, Top),
        drain_events_until_prompt(Out, Timeout, EventsB),
        append(EventsA, EventsB, Events)
    ;   GoalGiven \== ""
    ->  send_profile_goal(In, GoalGiven, Top),
        drain_events_until_prompt(Out, Timeout, Events)
    ;   NodeGiven \== ""
    ->  send_profile_node(In, NodeGiven, Top),
        drain_events_until_prompt(Out, Timeout, Events)
    ;   Events = []
    ),
    drain_stderr_nonblock(Err, ErrText),
    (   Events == [], GoalGiven == "", NodeGiven == ""
    ->  Text = "target_profile needs either `goal` or `node`."
    ;   render_events_with_stderr(Events, ErrText, Text)
    ).

drain_events_until_prompt(Out, Timeout, Events) :-
    drain_until_prompt(Out, Timeout, Events).

send_profile_goal(In, GoalStr, Top) :-
    format(In, "mcp_target:mcp_profile((~w), ~w).~n",
           [GoalStr, Top]),
    flush_output(In).

send_profile_node(In, NodeStr, Top) :-
    format(In, "mcp_target:mcp_profile_node('~w', ~w).~n",
           [NodeStr, Top]),
    flush_output(In).


:- mcp_tool(
       target_coverage,
       "Run library(prolog_coverage) in the target and return the data \c
        as a structured summary, or drill into one file's clauses.  \c
        With `goal`, runs coverage(Goal) and emits a per-file summary \c
        (total / covered / failed / uncovered clauses, %covered) for \c
        the top-N files sorted by uncovered-count descending; the \c
        cached data is stashed in the target so follow-up drill-ins \c
        do not need to re-run.  With `file`, returns the clause-level \c
        breakdown (predicate indicator, line, enter / exit counts) \c
        for that file.  Both: re-run, then drill.  Optional `roots` is \c
        a list of directories (file-search-path aliases like \c
        'library(.)' also work); only files below one of them appear \c
        in the summary, which is the natural way to suppress noise \c
        from SWI's own libraries when you want user-code coverage only.",
       #{ type: object,
          properties:
              #{ goal:   #{type:string,
                           description:"Prolog goal to run under coverage"},
                 file:   #{type:string,
                           description:"File to drill into (absolute path \c
                                        or basename / unique suffix)"},
                 roots:  #{ type: array,
                            items: #{ type: string },
                            description:"Directories that scope the summary \c
                                         (passed to absolute_file_name/3 \c
                                         with file_type(directory), so \c
                                         'library(.)' etc. work)"
                          },
                 top:    #{type:integer, minimum:1, maximum:500,
                           description:"Cap on files (summary) or clauses \c
                                        per status group (drill); default 25"},
                 target: #{type:string,
                           description:"Target name (default 'default')"},
                 timeout: #{type:number, minimum:0.1, maximum:600}
               }
        }).

target_coverage(Args, Text) :-
    target_name(Args, Name),
    Timeout = Args.get(timeout, 120),
    Top     = Args.get(top, 25),
    (   target_proc(Name, _, In, Out, Err)
    ->  target_coverage_dispatch(Args, In, Out, Err, Top, Timeout, Text)
    ;   format(string(Text), "No running target named ~w", [Name])
    ).

target_coverage_dispatch(Args, In, Out, Err, Top, Timeout, Text) :-
    GoalGiven = Args.get(goal, ""),
    FileGiven = Args.get(file, ""),
    Roots     = Args.get(roots, []),
    (   GoalGiven \== "", FileGiven \== ""
    ->  send_coverage_goal(In, GoalGiven, Top, Roots),
        drain_events_until_prompt(Out, Timeout, EventsA),
        send_coverage_file(In, FileGiven, Top),
        drain_events_until_prompt(Out, Timeout, EventsB),
        append(EventsA, EventsB, Events)
    ;   GoalGiven \== ""
    ->  send_coverage_goal(In, GoalGiven, Top, Roots),
        drain_events_until_prompt(Out, Timeout, Events)
    ;   FileGiven \== ""
    ->  send_coverage_file(In, FileGiven, Top),
        drain_events_until_prompt(Out, Timeout, Events)
    ;   Events = []
    ),
    drain_stderr_nonblock(Err, ErrText),
    (   Events == [], GoalGiven == "", FileGiven == ""
    ->  Text = "target_coverage needs either `goal` or `file`."
    ;   render_events_with_stderr(Events, ErrText, Text)
    ).

send_coverage_goal(In, GoalStr, Top, Roots) :-
    roots_to_atom(Roots, RootsAtom),
    format(In, "mcp_target:mcp_coverage((~w), ~w, ~w).~n",
           [GoalStr, Top, RootsAtom]),
    flush_output(In).

%  Roots arrives as a list of strings; serialise as a Prolog list of
%  quoted atoms so absolute_file_name/3 inside the target can resolve
%  file-search-path aliases like 'library(.)'.
roots_to_atom([], '[]') :- !.
roots_to_atom(Roots, Atom) :-
    maplist(root_term, Roots, Terms),
    format(atom(Atom), "~q", [Terms]).

root_term(Root, Term) :-
    atom_string(RA, Root),
    %  Heuristic: an absolute path starts with `/` and stays an atom;
    %  a search-path spec like `library(foo)` starts with a letter
    %  and gets read as a compound term so absolute_file_name/3 can
    %  resolve the alias inside the target.
    (   sub_atom(RA, 0, 1, _, First),
        char_type(First, alpha),
        sub_atom(RA, _, _, _, '(')
    ->  catch(term_string(Term, RA), error(_,_), Term = RA)
    ;   Term = RA
    ).

send_coverage_file(In, FileStr, Top) :-
    format(In, "mcp_target:mcp_coverage_file(~q, ~w).~n",
           [FileStr, Top]),
    flush_output(In).


:- mcp_tool(
       target_input,
       "Send raw input text to a target that is awaiting user input \c
        (e.g.  via read/1 or a choicepoint prompt).  The text is sent \c
        verbatim followed by a newline.",
       #{ type: object,
          properties:
              #{ text:    #{type:string},
                 target:  #{type:string,
                            description:"Target name (default 'default')"},
                 timeout: #{type:number, minimum:0.1, maximum:300}
               },
          required: [text]
        }).

target_input(Args, Text) :-
    target_name(Args, Name),
    Timeout = Args.get(timeout, 10),
    target_run(Name, "~w~n", [Args.text], Timeout, Text).


                /*******************************
                *          INTERNALS           *
                *******************************/

target_name(Args, Name) :-
    (   N = Args.get(target)
    ->  atom_string(Name, N)
    ;   Name = default
    ).

%!  target_run(+Name, +Format, +Args, +Timeout, -Text) is det.
%
%   Write Format/Args to the target's stdin, drain its event stream
%   until the next prompt, drain whatever made it to stderr, and
%   render both into Text.  Returns "No running target named ~w" if
%   the named target is not currently registered.  Used by
%   target_send, target_load, target_check and target_input -- each
%   passes a Format string that frames its payload appropriately
%   ("~w .~n" for Prolog goals, "~w~n" for raw user input, etc.).

target_run(Name, Format, Args, Timeout, Text) :-
    (   target_proc(Name, _, In, Out, Err)
    ->  format(In, Format, Args),
        flush_output(In),
        drain_until_prompt(Out, Timeout, Events),
        drain_stderr_nonblock(Err, ErrText),
        render_events_with_stderr(Events, ErrText, Text)
    ;   format(string(Text), "No running target named ~w", [Name])
    ).

launch_target(Name, Files, Text) :-
    instrumentation_file(Instrumentation),
    %  --nopce disables xpce so library hooks (profile, edit, gtrace,
    %  etc.) fall through to their text-mode implementations -- the
    %  proxy can't drive a GUI.
    append([ '-q', '--nopce', '-l', Instrumentation ], Files, ProcArgs),
    catch(process_create(path(swipl), ProcArgs,
                         [ stdin(pipe(In)),
                           stdout(pipe(Out)),
                           stderr(pipe(Err)),
                           process(PID)
                         ]),
          Error,
          ( message_to_string(Error, EMsg),
            format(string(Text), "Failed to spawn swipl: ~w", [EMsg]),
            fail
          )),
    !,
    set_stream(In,  encoding(utf8)),
    set_stream(Out, encoding(utf8)),
    set_stream(Err, encoding(utf8)),
    %  Drain the startup events (banner + first toplevel prompt).
    %  Show any non-banner events (warnings from file load etc.) and
    %  whatever has reached stderr by this point.
    drain_until_prompt(Out, 10, StartupEvents),
    render_startup_events(StartupEvents, StartupText),
    drain_stderr_nonblock(Err, ErrText),
    assertz(target_proc(Name, PID, In, Out, Err)),
    format(string(Text),
           "Target ~w started: pid=~w files=~q~n~w~w",
           [Name, PID, Files, StartupText, ErrText]).

%!  render_startup_events(+Events, -Text) is det.
%
%   Drop the welcome banner and pass everything else through the
%   normal renderer.  Result is "" if there were no interesting
%   events.

render_startup_events(Events, Text) :-
    exclude(banner_event, Events, Interesting),
    (   Interesting == [prompt]
    ->  Text = ""
    ;   render_events(Interesting, Text)
    ).

banner_event(event(Dict)) :-
    is_dict(Dict),
    "message" == Dict.get(k),
    "welcome" == Dict.get(kind).
banner_event(text(S)) :-
    %  Drop pure-whitespace runs.
    split_string(S, "", " \n\r\t", [""]).


%!  drain_stderr_nonblock(+Stream, -Text) is det.
%
%   Wait up to 50ms for any pending stderr bytes (long enough for the
%   OS to deliver writes that happened during the just-finished goal),
%   then read everything currently in the pipe without blocking
%   further.  Returns "" if nothing showed up.

drain_stderr_nonblock(Stream, Text) :-
    drain_stderr_(Stream, 0.05, Codes),
    (   Codes == []
    ->  Text = ""
    ;   format(string(Text), "~n[stderr]~n~s", [Codes])
    ).

drain_stderr_(Stream, Timeout, Out) :-
    wait_for_input([Stream], Ready, Timeout),
    (   Ready == []
    ->  Out = []
    ;   at_end_of_stream(Stream)
    ->  Out = []
    ;   read_pending_codes(Stream, Out, Tail),
        drain_stderr_(Stream, 0.01, Tail)
    ).

render_events_with_stderr(Events, "", Text) :- !,
    render_events(Events, Text).
render_events_with_stderr(Events, ErrText, Text) :-
    render_events(Events, Main),
    format(string(Text), "~w~w", [Main, ErrText]).

instrumentation_file(Path) :-
    source_file(instrumentation_file(_), ThisFile),
    file_directory_name(ThisFile, ServersDir),
    file_directory_name(ServersDir, McpDir),
    directory_file_path(McpDir,
                        'target_toplevel/mcp_target.pl', Path).


                /*******************************
                *      EVENT RENDERING         *
                *******************************/

%!  render_events(+Events, -Text) is det.
%
%   Render the drained event list into a single human-readable
%   text block.  Plain text segments are emitted as-is; structured
%   events are summarised.

render_events(Events, Text) :-
    with_output_to(string(Text), render_events_(Events)).

render_events_([]).
render_events_([H|T]) :-
    render_event(H),
    render_events_(T).

:- discontiguous render_event/1.
render_event(text(S)) :-
    (   S == "" -> true ; format("~w", [S]) ).
render_event(event(Dict)) :-
    "message" == Dict.get(k), !,
    Level = Dict.get(level),
    Body  = Dict.get(text),
    format("[~w] ~w~n", [Level, Body]).
render_event(event(Dict)) :-
    "trace" == Dict.get(k), !,
    Port  = Dict.get(port),
    Goal  = Dict.get(goal),
    Depth = Dict.get(depth),
    format("[trace ~w  (depth ~w)]  ~w~n", [Port, Depth, Goal]).
render_event(event(Dict)) :-
    "prompt" == Dict.get(k),
    "trace" == Dict.get(kind), !,
    format("[awaiting debugger command: c/s/l/f/r/a]~n").
render_event(event(Dict)) :-
    "prompt" == Dict.get(k),
    "read" == Dict.get(kind), !,
    format("[awaiting input -- use target_input]~n").
render_event(event(Dict)) :-
    "profile_summary" == Dict.get(k), !,
    render_profile_summary(Dict).
render_event(event(Dict)) :-
    "profile_node" == Dict.get(k), !,
    render_profile_node(Dict).
render_event(event(Dict)) :-
    "coverage_summary" == Dict.get(k), !,
    render_coverage_summary(Dict).
render_event(event(Dict)) :-
    "coverage_file" == Dict.get(k), !,
    render_coverage_file(Dict).
render_event(event(Dict)) :-
    "prompt" == Dict.get(k), !.        % silent end-of-turn marker
render_event(event(_)).

render_profile_summary(Dict) :-
    S = Dict.summary,
    format("Profile summary: ~3f s wall, ~w samples, ~w ticks, ~w nodes~n",
           [S.time, S.samples, S.ticks, S.nodes]),
    format("  ~w~t~50|~tCalls~12+~tRedos~10+~tExits~10+~tSelf~10+~tChild~10+~n",
           ["Predicate"]),
    forall(member(R, Dict.top),
           format("  ~w~t~50|~t~w~12+~t~w~10+~t~w~10+~t~w~10+~t~w~10+~n",
                  [R.predicate, R.call, R.redo, R.exit,
                   R.ticks_self, R.ticks_siblings])).

render_coverage_summary(Dict) :-
    NShown = Dict.files,
    length(NShown, N),
    format("Coverage summary: ~w of ~w files shown (sorted by uncovered, desc)~n",
           [N, Dict.total_files]),
    format("  ~w~t~70|~tClauses~10+~tCov~6+~tFail~6+~tUncov~6+ ~t%Cov~7+~n",
           ["File"]),
    forall(member(F, NShown),
           format("  ~w~t~70|~t~w~10+~t~w~6+~t~w~6+~t~w~6+ ~t~2f~7+~n",
                  [F.file, F.total, F.covered, F.failed,
                   F.uncovered, F.pct_covered])).

render_coverage_file(Dict) :-
    (   Err = Dict.get(error)
    ->  format("Coverage file lookup failed: ~w~n", [Err])
    ;   F = Dict.file,
        format("File ~w  total=~w  covered=~w  failed=~w  uncovered=~w~n",
               [F.file, F.total, F.covered, F.failed, F.uncovered]),
        format("  ~w~t~12|~w~t~50|~tline~6+~tenter~8+~texit~8+~n",
               ["status", "predicate"]),
        forall(member(C, F.clauses),
               format("  ~w~t~12|~w~t~50|~t~w~6+~t~w~8+~t~w~8+~n",
                      [C.status, C.pi, C.line, C.enter, C.exit]))
    ).

render_profile_node(Dict) :-
    (   Err = Dict.get(error)
    ->  format("Profile node lookup failed: ~w~n", [Err])
    ;   N = Dict.node,
        format("Node ~w  call=~w  redo=~w  exit=~w  self=~w  child=~w~n",
               [N.predicate, N.call, N.redo, N.exit,
                N.ticks_self, N.ticks_siblings]),
        format("  Callers:~n", []),
        forall(member(C, N.callers),
               format("    ~w~t~40|~t~w/~w/~w~12+ ~tself=~w~10+ ~tchild=~w~10+~n",
                      [C.predicate, C.call, C.redo, C.exit,
                       C.ticks_self, C.ticks_siblings])),
        format("  Callees:~n", []),
        forall(member(C, N.callees),
               format("    ~w~t~40|~t~w/~w/~w~12+ ~tself=~w~10+ ~tchild=~w~10+~n",
                      [C.predicate, C.call, C.redo, C.exit,
                       C.ticks_self, C.ticks_siblings]))
    ).
render_event(prompt) :- !.
render_event(timeout) :- format("[mcp:timeout — child still running, may be awaiting input]~n").
render_event(eof)     :- format("[mcp:eof — child exited]~n").
