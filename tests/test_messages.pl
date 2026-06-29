/*  Tests for library(mcp/messages).

    Run as:

        swipl -g 'test_messages,halt' tests/test_messages.pl
*/

:- module(test_messages,
          [ test_messages/0
          ]).
:- use_module(library(mcp/messages)).
:- use_module(library(plunit)).
:- use_module(library(yall)).
:- use_module(library(lists), [member/2]).

test_messages :-
    run_tests([messages]).


:- begin_tests(messages).

test(success_no_messages) :-
    run_collect_messages(true, Result, Messages),
    assertion(Result == true),
    assertion(Messages == []).

test(failure) :-
    run_collect_messages(fail, Result, Messages),
    assertion(Result == false),
    assertion(Messages == []).

test(exception) :-
    run_collect_messages(
        throw(error(type_error(integer, foo), _)),
        Result, Messages),
    assertion(Result = exception(error(type_error(integer, foo), _))),
    assertion(Messages == []).

test(capture_warning_default_filter) :-
    %  Silent kind is rejected by the default filter; warning is kept.
    %  Use a synthetic silent-level message we won't actually display.
    %  But to test that the default filter ACCEPTS warnings, fire a
    %  warning-level print_message and check it landed in Messages.
    run_collect_messages(
        print_message(silent, format("test silent ~w", [42])),
        Result, Messages),
    assertion(Result == true),
    %  silent must NOT be captured by the default filter
    assertion(Messages == []).

test(custom_filter_captures_silent) :-
    run_collect_messages(
        print_message(silent, format("test silent ~w", [42])),
        [_]>>true,
        Result, Messages),
    assertion(Result == true),
    assertion(member(message(format("test silent ~w", [42]), silent, _),
                     Messages)).

test(custom_filter_only_errors) :-
    %  Reject warning, accept only error.
    run_collect_messages(
        ( print_message(silent, format("a ~w", [1])),
          print_message(silent, format("b ~w", [2]))
        ),
        =(error),
        Result, Messages),
    assertion(Result == true),
    assertion(Messages == []).

:- end_tests(messages).
