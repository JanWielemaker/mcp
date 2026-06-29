/*  Smoke tests for the tools registered by library(mcp/servers/swipl_kernel).

    Builds a tiny synthetic C tree under tmp_directory/0 and points the
    `mcp_swipl_kernel:c_source_root` setting at it so the tests do not
    depend on the real swipl-devel checkout being present.

    Run as:

        swipl -g 'test_swipl_kernel,halt' tests/test_swipl_kernel.pl
*/

:- module(test_swipl_kernel,
          [ test_swipl_kernel/0
          ]).
:- use_module(library(mcp/server)).
:- use_module(library(mcp/servers/swipl_kernel)).
:- use_module(library(plunit)).
:- use_module(library(settings), [setting/2, set_setting/2]).
:- use_module(library(filesex),
              [ directory_file_path/3,
                make_directory_path/1,
                delete_directory_and_contents/1
              ]).
:- use_module(library(debug), [assertion/1]).
:- use_module(test_utils, [tool_call/3]).

:- mcp_server_info(#{name:"test-swipl-kernel", version:"0.0"}).

test_swipl_kernel :-
    run_tests([swipl_kernel]).


:- begin_tests(swipl_kernel,
               [ setup(setup_kernel_fixture(Saved, Dir)),
                 cleanup(cleanup_kernel_fixture(Saved, Dir))
               ]).

test(c_grep_finds_function) :-
    tool_call("c_grep", #{pattern:"my_test_function"}, Text),
    assertion(sub_string(Text, _, _, _, "my_test_function")),
    assertion(sub_string(Text, _, _, _, "test.c")).

test(c_grep_pred_impl) :-
    tool_call("c_grep", #{pattern:"PRED_IMPL"}, Text),
    assertion(sub_string(Text, _, _, _, "PRED_IMPL")),
    assertion(sub_string(Text, _, _, _, "my_pred")).

test(c_grep_no_match) :-
    tool_call("c_grep",
              #{pattern:"this_pattern_will_definitely_not_be_present_xyzzy"},
              Text),
    assertion(sub_string(Text, _, _, _, "0 matches")).

test(c_function_defs_function) :-
    %  Path relative to the c_source_root is resolved by the tool.
    tool_call("c_function_defs", #{file:"test.c"}, Text),
    assertion(sub_string(Text, _, _, _, "my_test_function")),
    assertion(sub_string(Text, _, _, _, "PRED_IMPL")).

test(c_function_defs_missing_file) :-
    tool_call("c_function_defs", #{file:"no_such_file.c"}, Text),
    assertion(sub_string(Text, _, _, _, "not found")).

:- end_tests(swipl_kernel).


%  Fixture --------------------------------------------------------------

%!  setup_kernel_fixture(-Saved, -Dir) is det.
%
%   Build a tiny C tree and repoint the kernel root setting at it.
%   Saved is the previous value (restored in cleanup); Dir is the
%   tmp directory we created (removed in cleanup).

setup_kernel_fixture(Saved, Dir) :-
    setting(mcp_swipl_kernel:c_source_root, Saved),
    tmp_file('mcp_kernel_test', Dir),
    make_directory_path(Dir),
    directory_file_path(Dir, 'test.c', CFile),
    setup_call_cleanup(
        open(CFile, write, S, [encoding(utf8)]),
        write(S,
"/* fixture file for the swipl_kernel test */
#include <stdio.h>

int my_test_function(int x)
{
    return x + 1;
}

static
PRED_IMPL(\"my_pred\", 1, my_pred, 0)
{ return TRUE;
}
"),
        close(S)),
    set_setting(mcp_swipl_kernel:c_source_root, Dir).

cleanup_kernel_fixture(Saved, Dir) :-
    set_setting(mcp_swipl_kernel:c_source_root, Saved),
    catch(delete_directory_and_contents(Dir), error(_,_), true).
