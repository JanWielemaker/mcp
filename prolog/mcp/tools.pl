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

:- module(mcp_tools,
          [ list_tools/1,               % -Tools
            call_tool/2                 % +Params, -Result
          ]).
:- use_module(library(mcp/content), [mcp_to_content_list/2]).
:- use_module(library(json_schema), [json_check/3]).
:- use_module(library(debug), [debug/3]).
:- use_module(server, [mcp_current_tool/4, mcp_current_tool_raw_schema/3]).

/** <module> tools/list and tools/call

Builds the `tools/list` response from the global tool registry and
dispatches `tools/call` to the registered handler in its declaring
module.

Handler contract:

    Handler(+Args:dict, -Content)

If the call raises an exception the result is reported back with
`isError:true` so the LLM can recover, rather than as a JSON-RPC
error.  Schema-validation failures use the JSON-RPC `Invalid params`
error code -32602 because they indicate a client-side mistake.
*/

%!  list_tools(-Tools:list) is det.

list_tools(Tools) :-
    findall(Tool, current_tool(Tool), Tools).

current_tool(#{name:NameS, description:Desc, inputSchema:Schema}) :-
    mcp_current_tool(Module, Name, Desc, _Compiled),
    mcp_current_tool_raw_schema(Module, Name, Schema),
    atom_string(Name, NameS).


%!  call_tool(+Params, -Result) is det.
%
%   Params is `#{name:Name, arguments:Args}`.

call_tool(Params, Result) :-
    NameS = Params.get(name),
    atom_string(Name, NameS),
    Args = Params.get(arguments, #{}),
    (   mcp_current_tool(Module, Name, _Desc, CompiledSchema)
    ->  validate_args(CompiledSchema, Args),
        run_tool(Module, Name, Args, Result)
    ;   throw(mcp_error(-32602, "Unknown tool", #{name: NameS}))
    ).

validate_args(CompiledSchema, Args) :-
    Error = error(_,_),
    catch(json_check(CompiledSchema, Args, []),
          Error,
          (   message_to_string(Error, Msg),
              throw(mcp_error(-32602, "Invalid params", #{data:Msg}))
          )).

run_tool(Module, Name, Args, Result) :-
    debug(mcp(tools), 'call ~w:~w(~p)', [Module, Name, Args]),
    %  once/1: tool predicates routinely use a two-clause
    %  primary/fallback pattern (`tool(_, "failed"). `) and leave a
    %  choice point on success.  Without committing here mcp_dispatch
    %  itself is non-det, which breaks setup_call_cleanup callers --
    %  cleanup defers past following operations and a memory_file
    %  write stream stays open into the read step.
    catch(once(call(Module:Name, Args, Raw)),
          Error,
          tool_error(Error, Result)),
    (   nonvar(Result)
    ->  true
    ;   mcp_to_content_list(Raw, Content),
        Result = #{content:Content, isError:false}
    ).

tool_error(Error, #{content:[#{type:"text", text:Msg}], isError:true}) :-
    message_to_string(Error, Msg),
    debug(mcp(tools), 'tool raised: ~w', [Msg]).
