/*  Smoke tests for the tools registered by library(mcp/servers/git).

    These tests need a real git work-tree to query.  The root is taken
    from the Prolog flag `mcp_test_swipl_devel_root`, which defaults
    to `~/src/swipl-devel`.  Override on the command line with

        swipl -Dmcp_test_swipl_devel_root=/path/to/swipl-devel \
              -g 'test_git,halt' tests/test_git.pl

    The test unit is skipped if the root either does not exist on
    disk or is not a git work-tree, so these tests are safe to run on
    a machine without a checkout.

    Run as:

        swipl -g 'test_git,halt' tests/test_git.pl
*/

:- module(test_git,
          [ test_git/0
          ]).
:- use_module(library(mcp/server)).
:- use_module(library(mcp/servers/source)).
:- use_module(library(mcp/servers/git)).
:- use_module(library(plunit)).
:- use_module(library(filesex), [delete_directory_and_contents/1]).
:- use_module(library(debug), [assertion/1]).
:- use_module(library(git), [is_git_directory/1]).
:- use_module(test_utils, [tool_call/3]).

:- mcp_server_info(#{name:"test-git", version:"0.0"}).

test_git :-
    run_tests([git]).


:- begin_tests(git,
               [ condition(have_test_git_root)
               ]).

test(git_log) :-
    tool_call("git_log",
              #{root:"swipl-source", max:3},
              Text),
    assertion(sub_string(Text, _, _, _, "swipl-source:")),
    %  git's --pretty=format:%h..%s yields a line per commit; with
    %  max:3 there must be at least one match for the SHA-prefix
    %  shape (hex chars followed by two spaces).
    assertion(sub_string(Text, _, _, _, "  ")).

test(git_log_with_path) :-
    tool_call("git_log",
              #{root:"swipl-source", path:"README.md", max:2},
              Text),
    assertion(sub_string(Text, _, _, _, "swipl-source:")).

test(git_blame_readme) :-
    tool_call("git_blame",
              #{root:"swipl-source", path:"README.md",
                start_line:1, end_line:3},
              Text),
    assertion(sub_string(Text, _, _, _, "README.md")),
    assertion(sub_string(Text, _, _, _, "lines 1-3")).

test(git_show_head) :-
    tool_call("git_show",
              #{root:"swipl-source", commit:"HEAD"},
              Text),
    assertion(sub_string(Text, _, _, _, "swipl-source")),
    %  `git show HEAD` always reports the commit identifier.
    assertion(sub_string(Text, _, _, _, "commit ")).

test(git_show_file_at_head) :-
    tool_call("git_show",
              #{root:"swipl-source", commit:"HEAD", path:"README.md"},
              Text),
    assertion(sub_string(Text, _, _, _, "README.md@HEAD")).

test(git_diff_head_with_head) :-
    %  HEAD..HEAD is an empty diff but exits 0.
    tool_call("git_diff",
              #{root:"swipl-source", ref1:"HEAD", ref2:"HEAD"},
              Text),
    assertion(sub_string(Text, _, _, _, "HEAD..HEAD")).

test(git_grep_pred_impl) :-
    tool_call("git_grep",
              #{root:"swipl-source", pattern:"PRED_IMPL",
                max_results:5},
              Text),
    assertion(sub_string(Text, _, _, _, "PRED_IMPL")),
    assertion(sub_string(Text, _, _, _, "matches")).

test(git_grep_no_match) :-
    tool_call("git_grep",
              #{root:"swipl-source",
                pattern:"this_pattern_will_definitely_not_match_qqqxyzzy"},
              Text),
    assertion(sub_string(Text, _, _, _, "No matches")).

test(git_unknown_root) :-
    tool_call("git_log",
              #{root:"no_such_root_xyzzy", max:1},
              Text),
    assertion(sub_string(Text, _, _, _, "Unknown root")).

test(git_non_git_root,
     [ setup(register_non_git_root(Dir)),
       cleanup(cleanup_non_git_root(Dir))
     ]) :-
    tool_call("git_log",
              #{root:"_mcp_test_non_git_root", max:1},
              Text),
    assertion(sub_string(Text, _, _, _, "not a git work-tree")).

:- end_tests(git).


%  Setup helpers --------------------------------------------------------

have_test_git_root :-
    source_root_path('swipl-source', Root),
    is_git_directory(Root).

%  A tmp directory that exists but is NOT a git work-tree, registered as
%  a multifile source_root/2 so we can drive git_root/4's "not a git
%  work-tree" branch from the dispatcher.

:- multifile mcp_server_source:source_root/2.
:- dynamic   non_git_root_dir/1.

mcp_server_source:source_root('_mcp_test_non_git_root', Dir) :-
    non_git_root_dir(Dir).

register_non_git_root(Dir) :-
    tmp_file('mcp_non_git', Dir),
    make_directory(Dir),
    assertz(non_git_root_dir(Dir)).

cleanup_non_git_root(Dir) :-
    retractall(non_git_root_dir(_)),
    catch(delete_directory_and_contents(Dir), error(_,_), true).
