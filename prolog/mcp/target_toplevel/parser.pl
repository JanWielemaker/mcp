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
:- use_module(library(time), [call_with_time_limit/2]).

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

drain_until_prompt(Stream, TimeoutSec, Events) :-
    catch(call_with_time_limit(TimeoutSec,
                               drain(Stream, [], EventsR)),
          time_limit_exceeded,
          EventsR = [timeout]),
    reverse(EventsR, Events).

%  drain/3 alternates between two states:
%
%    - OUTSIDE an event: read plain text up to the next SOH (or EOF)
%      with read_string/5 stopping on SOH (0x01).
%    - INSIDE an event:  read the JSON body up to the next ETX (0x03)
%      with read_event/2.
%
%  read_string/5 consumes the stop char, so   after each call we already
%  know we are either at EOF (Sep ==  -1)   or  just past an SOH (Sep ==
%  0x01) and should call read_event next.

drain(Stream, Acc, Out) :-
    read_string(Stream, "\u0001", "", Sep, Text),
    pre_event_acc(Text, Acc, Acc1),
    (   Sep == 0x01
    ->  read_event(Stream, Event),
        (   is_prompt(Event)
        ->  Out = [event(Event), prompt|Acc1]
        ;   drain(Stream, [event(Event)|Acc1], Out)
        )
    ;   Out = [eof|Acc1]                 % Sep == -1, EOF
    ).

pre_event_acc("", Acc, Acc) :- !.
pre_event_acc(Text, Acc, [text(Text)|Acc]).

%  Read the JSON body up to ETX, then JSON-decode the buffer.
read_event(Stream, Dict) :-
    read_string(Stream, "\u0003", "", _Sep, JSON),
    atom_json_dict(JSON, Dict, []).

is_prompt(Dict) :-
    is_dict(Dict),
    "prompt" == Dict.get(k).
