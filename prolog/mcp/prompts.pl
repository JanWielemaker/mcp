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

:- module(mcp_prompts,
          [ list_prompts/1,             % -Prompts
            get_prompt/2                % +Params, -Result
          ]).
:- use_module(library(debug), [debug/3]).
:- use_module(server).

/** <module> prompts/list and prompts/get

Handler contract for a prompt named N declared in module M:

    M:N(+Args:dict, -Messages:list) is det.

where each message is a dict `#{role:R, content:C}`.  R is "user" or
"assistant".  C is a content dict (see library(mcp/content)).
*/

%!  list_prompts(-Prompts) is det.

list_prompts(Prompts) :-
    findall(P, current_prompt(P), Prompts).

current_prompt(#{name:NameS, description:Desc, arguments:Args}) :-
    mcp_current_prompt(_Module, Name, Desc, Args),
    atom_string(Name, NameS).

%!  get_prompt(+Params, -Result) is det.
%
%   Params is `#{name:Name, arguments:Args}`.

get_prompt(Params, #{messages:Messages, description:Desc}) :-
    NameS = Params.get(name),
    atom_string(Name, NameS),
    Args = Params.get(arguments, #{}),
    (   mcp_current_prompt(Module, Name, Desc, _Args)
    ->  debug(mcp(prompts), 'get ~w:~w(~p)', [Module, Name, Args]),
        call(Module:Name, Args, Messages)
    ;   throw(mcp_error(-32602, "Unknown prompt", #{name: NameS}))
    ).
