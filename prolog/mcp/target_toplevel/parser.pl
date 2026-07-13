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

:- module(mcp_target_parser,
          [ drain_until_prompt/3        % +Stream, +TimeoutSec, -Events
          ]).

:- use_module(library(json), [atom_json_dict/3]).

/** <module> Demultiplexer for the magic-marker stream from mcp_target.pl

The child swipl frames structured  events   between  SOH  (0x01) and ETX
(0x03). Everything outside those markers is plain user output. Both ends
use UTF-8 encoding --  SOH/ETX  are   ASCII  codepoints,  so the markers
survive untouched while non-ASCII text inside   events  and plain output
round-trips through library(json) and read_string/5 without re-encoding.

Events are returned as a list of:

  - text(String)         a run of plain text between magic events
  - event(Dict)          a JSON-decoded structured event
  - timeout              the per-call wall-clock timeout fired
  - eof                  the stream closed before a prompt arrived

The last element is always one of `prompt`, `timeout` or `eof`.
*/

%!  drain_until_prompt(+Stream, +TimeoutSec, -Events) is det.
%
%   Read the child's stdout until a prompt event is seen, EOF is
%   reached, or the wall-clock deadline is hit. The deadline is
%   enforced by wait_for_input/3 rather than call_with_time_limit/2 —
%   the latter delivers SIGALRM to the process, and after that fires
%   subsequent read_string/5 calls on the same stream in the same
%   call chain return no data (silent drain failures observed when
%   recovering from a runaway goal via SIGINT).

drain_until_prompt(Stream, TimeoutSec, Events) :-
    get_time(T0),
    Deadline is T0 + TimeoutSec,
    drain(Stream, Deadline, [], EventsR),
    reverse(EventsR, Events).

%  drain/4 alternates between two states:
%
%    - OUTSIDE an event: read plain text up to the next SOH (or EOF)
%      with read_string/5 stopping on SOH (0x01).
%    - INSIDE an event:  read the JSON body up to the next ETX (0x03)
%      with read_event/2.
%
%  Before each outer read we wait_for_input/3 up to the remaining
%  deadline. A timed-out wait terminates the drain with `timeout`.

drain(Stream, Deadline, Acc, Out) :-
    (   ready_or_timeout(Stream, Deadline)
    ->  read_string(Stream, "", "", Sep, Text),
        pre_event_acc(Text, Acc, Acc1),
        (   Sep == 0x01
        ->  read_event(Stream, Event),
            (   is_prompt(Event)
            ->  Out = [event(Event), prompt|Acc1]
            ;   drain(Stream, Deadline, [event(Event)|Acc1], Out)
            )
        ;   Out = [eof|Acc1]                 % Sep == -1, EOF
        )
    ;   Out = [timeout|Acc]
    ).

%  Succeed when Stream is readable, fail when the wall-clock Deadline
%  has been reached.

ready_or_timeout(Stream, Deadline) :-
    get_time(Now),
    Remaining is Deadline - Now,
    Remaining > 0,
    wait_for_input([Stream], Ready, Remaining),
    Ready == [Stream].

pre_event_acc("", Acc, Acc) :- !.
pre_event_acc(Text, Acc, [text(Text)|Acc]).

%  Read the JSON body up to ETX, then JSON-decode the buffer.
read_event(Stream, Dict) :-
    read_string(Stream, "", "", _Sep, JSON),
    atom_json_dict(JSON, Dict, []).

is_prompt(Dict) :-
    is_dict(Dict),
    "prompt" == Dict.get(k).
