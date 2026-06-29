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

:- module(mcp_messages,
          [ run_collect_messages/3,     % :Goal, -Result, -Messages
            run_collect_messages/4      % :Goal, :Filter, -Result, -Messages
          ]).

/** <module> Run a goal and collect print_message/2 output

Adapted from library(check_installation):run_collect_messages/3. Used by
MCP  server  tools  that  need  to  run  a  goal  (typically  make/0  or
xref_source/2) and report the warnings/errors it   produces  back to the
caller instead of letting them print to user_error.
*/

:- meta_predicate
    run_collect_messages(0, -, -),
    run_collect_messages(0, 1, -, -).

:- thread_local
    got_message/1.

%!  run_collect_messages(:Goal, -Result, -Messages) is det.
%
%   Run Goal under a  thread-local  hook   that  captures  `warning` and
%   `error` messages. Result is `true`,   `false` or `exception(Error)`.
%   Messages is a list of `message(Term, Kind, Lines)` in the order they
%   were produced. See message_hook/3.

run_collect_messages(Goal, Result, Messages) :-
    run_collect_messages(Goal, error_kind, Result, Messages).

%!  run_collect_messages(:Goal, :Filter, -Result, -Messages) is det.
%
%   As run_collect_messages/3, but Filter is called as call(Filter,
%   Kind) to decide whether a message at level Kind is captured.

run_collect_messages(Goal, Filter, Result, Messages) :-
    setup_call_cleanup(
        asserta((user:thread_message_hook(Term, Kind, Lines) :-
                    call(Filter, Kind),
                    assertz(got_message(message(Term, Kind, Lines)))), Ref),
        (   E = error(Formal, _),
            catch(Goal, E, true)
        ->  (   var(Formal)
            ->  Result0 = true
            ;   Result0 = exception(E)
            )
        ;   Result0 = false
        ),
        erase(Ref)),
    findall(Msg, retract(got_message(Msg)), Messages),
    Result = Result0.

error_kind(warning).
error_kind(error).
