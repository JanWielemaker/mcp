/*  Smoke tests for the tools registered by library(mcp/servers/prolog_help).

    Run as:

        swipl -g 'test_prolog_help,halt' tests/test_prolog_help.pl
*/

:- module(test_prolog_help,
          [ test_prolog_help/0
          ]).
:- use_module(library(mcp/server)).
:- use_module(library(mcp/servers/prolog_help)).
:- use_module(library(plunit)).
:- use_module(library(debug), [assertion/1]).
:- use_module(test_utils, [tool_call/3, with_temp_file/3]).

:- mcp_server_info(#{name:"test-prolog-help", version:"0.0"}).

test_prolog_help :-
    run_tests([prolog_help]).


:- begin_tests(prolog_help).

%  pldoc_signature -------------------------------------------------------

test(pldoc_signature_append) :-
    tool_call("pldoc_signature", #{name:"append", arity:3}, Text),
    assertion(sub_string(Text, _, _, _, "append/3")),
    assertion(sub_string(Text, _, _, _, "List1AndList2")),
    assertion(sub_string(Text, _, _, _, "Summary:")).

test(pldoc_signature_meta_predicate) :-
    tool_call("pldoc_signature", #{name:"maplist", arity:2}, Text),
    assertion(sub_string(Text, _, _, _, "Meta-predicate")),
    assertion(sub_string(Text, _, _, _, "maplist(1,?)")).

test(pldoc_signature_dcg_source_arity) :-
    %  DCG predicate queryable by source arity (N) or callable arity (N+2)
    tool_call("pldoc_signature", #{name:"string_without", arity:2}, Text),
    assertion(sub_string(Text, _, _, _, "string_without")),
    assertion(sub_string(Text, _, _, _, "//")).

test(pldoc_signature_unknown) :-
    tool_call("pldoc_signature",
              #{name:"this_predicate_definitely_does_not_exist", arity:7},
              Text),
    %  Unknown predicate -- main clause still produces a structured
    %  "no info" report rather than falling through to the failure
    %  fallback.
    assertion(sub_string(Text, _, _, _, "(no PlDoc mode declarations)")),
    assertion(sub_string(Text, _, _, _, "(no summary available)")).

%  predicate_property_summary -------------------------------------------

test(predicate_property_summary_maplist) :-
    tool_call("predicate_property_summary",
              #{name:"maplist", arity:2}, Text),
    assertion(sub_string(Text, _, _, _, "apply")),
    assertion(sub_string(Text, _, _, _, "static")),
    assertion(sub_string(Text, _, _, _, "meta_predicate maplist(1,?)")).

test(predicate_property_summary_builtin) :-
    tool_call("predicate_property_summary",
              #{name:"format", arity:2}, Text),
    assertion(sub_string(Text, _, _, _, "built-in")),
    assertion(sub_string(Text, _, _, _, "system")).

test(predicate_property_summary_unknown) :-
    tool_call("predicate_property_summary",
              #{name:"no_such_predicate_at_all", arity:3}, Text),
    assertion(sub_string(Text, _, _, _, "No such predicate")).

%  module_exports -------------------------------------------------------

test(module_exports_lists) :-
    tool_call("module_exports", #{module:"lists"}, Text),
    assertion(sub_string(Text, _, _, _, "append/3")),
    assertion(sub_string(Text, _, _, _, "member/2")).

%  Temp-file based tools ------------------------------------------------

test(file_check_singleton) :-
    with_buggy_file(
        F,
        ( tool_call("file_check", #{file:F}, Text),
          assertion(sub_string(Text, _, _, _, "Singleton")),
          assertion(sub_string(Text, _, _, _, "undefined"))
        )).

test(file_xref_temp) :-
    with_buggy_file(
        F,
        ( tool_call("file_xref", #{file:F}, Text),
          assertion(sub_string(Text, _, _, _, "Defines")),
          assertion(sub_string(Text, _, _, _, "Calls"))
        )).

test(file_autoload_temp) :-
    with_buggy_file(
        F,
        ( tool_call("file_autoload", #{file:F}, Text),
          %  member/2 should appear in the suggested autoload directive
          assertion(sub_string(Text, _, _, _, "member"))
        )).

%  predicate_callers error paths -- the helper used to bind the message
%  to a local var and drop it on `fail`, falling through to the generic
%  "predicate_callers failed" fallback.  Lock the specific messages in.

test(predicate_callers_unknown_root) :-
    tool_call("predicate_callers",
              #{root:"no_such_root_xyz", name:"foo", arity:1},
              Text),
    assertion(sub_string(Text, _, _, _, "Unknown root")),
    assertion(sub_string(Text, _, _, _, "no_such_root_xyz")).

test(predicate_callers_bad_dir,
     [ condition(have_swipl_source_root) ]) :-
    tool_call("predicate_callers",
              #{root:"swipl-source",
                dir:"definitely_no_such_directory_qqqxyz",
                name:"foo", arity:1},
              Text),
    assertion(sub_string(Text, _, _, _, "Not a directory")).

:- end_tests(prolog_help).

have_swipl_source_root :-
    use_module(library(mcp/servers/source), [source_root_path/2]),
    source_root_path('swipl-source', _).


%  Fixture --------------------------------------------------------------

%  A small buggy Prolog source used by file_check / file_xref /
%  file_autoload tests.  Contains a singleton variable (Y, Z), a call
%  to an autoload-able predicate (member/2), and a call to an
%  undefined predicate (undefined_helper/2).

buggy_pl_content("\c
:- module(buggy, []).\n\c
\n\c
p(X) :-\n\c
    q(X, Y).\n\c
\n\c
q(_, _).\n\c
\n\c
go(L) :-\n\c
    member(X, L),\n\c
    undefined_helper(X, Z).\n").

with_buggy_file(File, Goal) :-
    buggy_pl_content(Content),
    with_temp_file(Content, File, Goal).
