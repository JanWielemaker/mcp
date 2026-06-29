/*  Integration tests for the tools registered by
    library(mcp/servers/target_toplevel).

    These tests spawn a real child swipl via process_create/3 and
    therefore require `swipl` to be on PATH.  Each test cleans up its
    target in a cleanup hook so a mid-test assertion failure does not
    leave a stray child process behind.

    Run as:

        swipl -g 'test_target_toplevel,halt' tests/test_target_toplevel.pl
*/

:- module(test_target_toplevel,
          [ test_target_toplevel/0
          ]).
:- use_module(library(mcp/server)).
:- use_module(library(mcp/servers/target_toplevel)).
:- use_module(library(plunit)).
:- use_module(library(debug), [assertion/1]).
:- use_module(test_utils, [tool_call/3, stop_target/1]).

:- mcp_server_info(#{name:"test-target-toplevel", version:"0.0"}).

test_target_toplevel :-
    run_tests([target_toplevel]).

%  Each target gets a distinct name so a leftover from a previous test
%  in the same process cannot mask a fresh-start regression.

:- begin_tests(target_toplevel).

test(target_lifecycle,
     [ cleanup(stop_target("test_lifecycle"))
     ]) :-
    Name = "test_lifecycle",
    tool_call("target_start", #{target:Name}, Started),
    assertion(sub_string(Started, _, _, _, "started")),
    tool_call("target_status", #{}, Status),
    assertion(sub_string(Status, _, _, _, Name)),
    tool_call("target_send",
              #{ target:Name,
                 goal:"X is 1+2, format(\"x=~w\", [X])"
               },
              SendOut),
    assertion(sub_string(SendOut, _, _, _, "x=3")),
    tool_call("target_stop", #{target:Name}, Stopped),
    assertion(sub_string(Stopped, _, _, _, "stopped")).

test(target_stop_unknown) :-
    %  Stopping a target that was never started must not crash; it
    %  should report the absence in a friendly way.
    tool_call("target_stop", #{target:"never_started_xyzzy"}, Text),
    assertion(sub_string(Text, _, _, _, "No running target")).

test(target_status_after_stop,
     [ cleanup(stop_target("status_after"))
     ]) :-
    Name = "status_after",
    tool_call("target_start", #{target:Name}, _),
    tool_call("target_stop",  #{target:Name}, _),
    tool_call("target_status", #{}, Status),
    %  After the stop the status output must not name the target.
    assertion(\+ sub_string(Status, _, _, _, Name)).

test(target_send_no_target) :-
    %  target_send to a non-existent target reports the absence.
    tool_call("target_send",
              #{ target:"never_started_xyzzy",
                 goal:"true"
               },
              Text),
    assertion(sub_string(Text, _, _, _, "No running target")).

test(target_check_default,
     [ cleanup(stop_target("check_default"))
     ]) :-
    %  Default (no `checks`) sends check/0; its informational header
    %  for the undefined-predicates pass is the most reliable anchor.
    Name = "check_default",
    tool_call("target_start", #{target:Name}, _),
    tool_call("target_check",
              #{target:Name, timeout:30},
              Text),
    assertion(sub_string(Text, _, _, _, "Checking undefined predicates")).

test(target_check_selective,
     [ cleanup(stop_target("check_selective"))
     ]) :-
    %  Selective: just list_undefined, identified by the warning
    %  header about predicates that may need :- dynamic.
    Name = "check_selective",
    tool_call("target_start", #{target:Name}, _),
    tool_call("target_check",
              #{target:Name,
                checks:["list_undefined"],
                timeout:30},
              Text),
    assertion(sub_string(Text, _, _, _, "not defined")).

test(target_check_no_target) :-
    tool_call("target_check",
              #{target:"never_started_xyzzy"},
              Text),
    assertion(sub_string(Text, _, _, _, "No running target")).

%  Stderr handling ------------------------------------------------------
%
%  drain_stderr_nonblock must produce the empty string when the child
%  wrote nothing to stderr, AND must surface stderr text under a clearly
%  marked block when it did.  The empty case regressed once (every
%  response grew a spurious "[stderr]" block); these tests lock both
%  shapes in.

test(target_stderr_empty,
     [ cleanup(stop_target("stderr_empty"))
     ]) :-
    Name = "stderr_empty",
    tool_call("target_start", #{target:Name}, _),
    %  A goal that writes only to user_output (i.e. captured as the
    %  query reply) must NOT cause a "[stderr]" block to appear.
    tool_call("target_send",
              #{ target:Name,
                 goal:"X is 1+2, format(\"x=~w\", [X])"
               },
              Out),
    assertion(sub_string(Out, _, _, _, "x=3")),
    assertion(\+ sub_string(Out, _, _, _, "[stderr]")).

test(target_stderr_surfaces,
     [ cleanup(stop_target("stderr_filled"))
     ]) :-
    Name = "stderr_filled",
    tool_call("target_start", #{target:Name}, _),
    %  Drive the child to write directly to user_error.  The drain must
    %  pick it up and label it as a [stderr] block in the response.
    tool_call("target_send",
              #{ target:Name,
                 goal:"format(user_error, \"hello_from_stderr~n\", [])"
               },
              Out),
    assertion(sub_string(Out, _, _, _, "[stderr]")),
    assertion(sub_string(Out, _, _, _, "hello_from_stderr")).

%  read_event/2 round-trip --------------------------------------------
%
%  These two exercise the SOH/ETX framing + JSON decode path end to
%  end: send a goal that drives mcp_target:mcp_emit/1 with a known
%  message dict and assert the rendered output contains the text we
%  injected.  The ASCII case is the basic framing guard; the unicode
%  case confirms read_string/5 + atom_json_dict/3 keep non-ASCII
%  intact (the json layer escapes to \u so the parser sees ASCII --
%  this test pins the round-trip property regardless).

test(target_event_roundtrip_ascii,
     [ cleanup(stop_target("event_ascii"))
     ]) :-
    Name = "event_ascii",
    tool_call("target_start", #{target:Name}, _),
    tool_call("target_send",
              #{ target:Name,
                 goal:"mcp_target:mcp_emit(#{k:message, level:info, \c
                                            kind:test, text:\"abc_XYZ_123\"})"
               },
              Out),
    assertion(sub_string(Out, _, _, _, "[info] abc_XYZ_123")).

test(target_event_roundtrip_unicode,
     [ cleanup(stop_target("event_unicode"))
     ]) :-
    Name = "event_unicode",
    tool_call("target_start", #{target:Name}, _),
    tool_call("target_send",
              #{ target:Name,
                 goal:"mcp_target:mcp_emit(#{k:message, level:info, \c
                                            kind:test, text:\"héllo_wörld\"})"
               },
              Out),
    assertion(sub_string(Out, _, _, _, "héllo_wörld")).

:- end_tests(target_toplevel).


