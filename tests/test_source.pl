/*  Smoke tests for the tools registered by library(mcp/servers/source).

    These tests need a real source tree to read from.  The root is
    taken from the Prolog flag `mcp_test_swipl_devel_root`, which
    defaults to `~/src/swipl-devel`.  Override on the command line
    with

        swipl -Dmcp_test_swipl_devel_root=/path/to/swipl-devel \
              -g 'test_source,halt' tests/test_source.pl

    The test unit is skipped if the root does not exist on disk, so
    these tests are safe to run on a machine without a checkout.

    Run as:

        swipl -g 'test_source,halt' tests/test_source.pl
*/

:- module(test_source,
          [ test_source/0
          ]).
:- use_module(library(mcp/server)).
:- use_module(library(mcp/servers/source), [source_root_path/2]).
:- use_module(library(plunit)).
:- use_module(library(debug), [assertion/1]).
:- use_module(test_utils, [tool_call/3]).

:- mcp_server_info(#{name:"test-source", version:"0.0"}).

test_source :-
    run_tests(
        [ source
        ]).

:- begin_tests(source,
               [ condition(have_test_root)
               ]).

test(source_roots) :-
    tool_call("source_roots", #{}, Text),
    assertion(sub_string(Text, _, _, _, "swipl")).

test(source_list_root) :-
    tool_call("source_list", #{root:"swipl"}, Text),
    assertion(sub_string(Text, _, _, _, "entries in swipl")).

test(source_list_glob) :-
    tool_call("source_list",
              #{root:"swipl-source", dir:"src", glob:"*.c"},
              Text),
    assertion(sub_string(Text, _, _, _, ".c")).

test(source_list_bad_root) :-
    tool_call("source_list",
              #{root:"no_such_root_xyzzy", dir:"."},
              Text),
    assertion(sub_string(Text, _, _, _, "Unknown or unsafe")).

test(source_read_header) :-
    %  README.md is reliably present at the swipl root.
    tool_call("source_read",
              #{root:"swipl-source", path:"README.md",
                start_line:1, end_line:5},
              Text),
    assertion(sub_string(Text, _, _, _, "swipl-source/README.md")),
    assertion(sub_string(Text, _, _, _, "lines 1-")).

test(source_read_unsafe_dotdot) :-
    tool_call("source_read",
              #{root:"swipl", path:"../escape.txt"},
              Text),
    assertion(sub_string(Text, _, _, _, "Unknown or unsafe")).

test(source_read_missing) :-
    tool_call("source_read",
              #{root:"swipl",
                path:"surely_no_such_file_qqq.txt"},
              Text),
    assertion(sub_string(Text, _, _, _, "Unknown or unsafe")).

test(source_search) :-
    tool_call("source_search",
              #{root:"swipl-source", pattern:"PRED_IMPL",
                file_glob:"*.c", max_results:5},
              Text),
    assertion(sub_string(Text, _, _, _, "PRED_IMPL")),
    assertion(sub_string(Text, _, _, _, "matches")).

test(source_search_unknown_root) :-
    tool_call("source_search",
              #{root:"no_such_root_xyzzy", pattern:"foo"},
              Text),
    assertion(sub_string(Text, _, _, _, "Unknown root")).

test(source_search_no_matches) :-
    %  grep exits 1 on no-match -- regression guard for the
    %  auto-reap-without-process(PID) variant of run_grep that mistook
    %  that for a failure and emitted "Grep failed: exit 1".
    tool_call("source_search",
              #{root:"swipl",
                pattern:"this_pattern_will_definitely_not_match_qqq_xyzzy"},
              Text),
    assertion(sub_string(Text, _, _, _, "0 matches")),
    assertion(\+ sub_string(Text, _, _, _, "Grep failed")).

:- end_tests(source).


%  Setup helpers --------------------------------------------------------

have_test_root :-
    source_root_path('swipl-source', Root),
    exists_directory(Root).
