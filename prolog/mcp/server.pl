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

:- module(mcp_server,
          [ mcp_tool/3,                 % +Name, +Description, +InputSchema
            mcp_resource/3,             % +URI, +Description, +Options
            mcp_resource_template/3,    % +UriTemplate, +Description, +Options
            mcp_prompt/3,               % +Name, +Description, +Arguments
            mcp_server_info/1,          % +Dict

            mcp_register_tool/4,        % +Module, +Name, +Description, +Schema
            mcp_register_resource/4,    % +Module, +URI, +Description, +Options
            mcp_register_resource_template/4, % +Module, +Tmpl, +Desc, +Opts
            mcp_register_prompt/4,      % +Module, +Name, +Description, +Args

            mcp_dispatch/3,             % :Stream, +Request, +Options
            mcp_protocol_version/1,     % -Atom

            mcp_set_rpc_stream/1,       % +Stream  (called by transport)
            mcp_notify/2,               % +Method, +Params
            mcp_get_server_info/1,      % -Dict
            mcp_current_prompt/4,
            mcp_current_resource/4,     % ?Module, ?URI, ?Description, ?Options
            mcp_current_tool/4,         % ?Module, ?URI, ?Description, ?Options
            mcp_current_resource_template/4, % ?Module, ?URI, ?Description, ?Options
            mcp_current_tool_raw_schema/3    % ?Module, ?Name, ?Schema
          ]).
:- use_module(library(json_schema), [json_compile_schema/3]).
:- use_module(library(debug), [debug/3]).
:- use_module(library(error), [must_be/2]).
:- use_module(library(json_rpc_common), [json_rpc_send/3]).
:- use_module(library(lists), [member/2]).

/** <module> MCP server framework

This  module  exposes  the  directives  used  to  declare  MCP  _tools_,
_resources_ and _prompts_, plus the dispatcher   invoked  by a transport
(stdio or HTTP). Transports are  provided   by  sibling  modules such as
library(mcp/stdio).

Tools, resources and prompts are registered into a global registry keyed
by the declaring module. The handler predicate   is  then called in that
module when a request arrives.

@see https://modelcontextprotocol.io/
*/

:- multifile
    mcp_server_info_hook/1.             % Hook to override serverInfo
:- meta_predicate
    mcp_tool(2, +, +),
    mcp_resource_template(3, +, +),
    mcp_prompt(2, +, +).


%!  mcp_protocol_version(-Version) is det.

mcp_protocol_version('2024-11-05').


                /*******************************
                *           REGISTRIES         *
                *******************************/

:- dynamic
    tool/4,                             % Module, Name, Description, CompiledSchema
    tool_raw_schema/3,                  % Module, Name, RawSchema
    resource/4,                         % Module, URI, Description, Options
    resource_template/4,                % Module, UriTemplate, Description, Options
    prompt/4,                           % Module, Name, Description, Arguments
    server_info/1,                      % Dict
    rpc_stream/1.                       % Output stream for server-initiated
                                        % notifications (set by stdio.pl)

:- multifile                            % several server modules contribute
    tool/4,
    tool_raw_schema/3,
    resource/4,
    resource_template/4,
    prompt/4.


%!  mcp_current_prompt(?Module, ?Name, ?Description, ?Arguments) is
%!                     nondet.
%
%   True when this is a prompt registered using mcp_prompt/3 in Module.

mcp_current_prompt(Module, Name, Description, Arguments) :-
    prompt(Module, Name, Description, Arguments).

%!  mcp_current_resource(?Module, ?URI, ?Description, ?Options) is
%!                       nondet.

mcp_current_resource(Module, URI, Description, Options) :-
    resource(Module, URI, Description, Options).

%!  mcp_current_resource_template(?Module, ?URI, ?Description, ?Options)
%!                                is nondet.

mcp_current_resource_template(Module, URI, Description, Options) :-
    resource_template(Module, URI, Description, Options).

%!  mcp_current_tool(?Module, ?URI, ?Description, ?Options) is nondet.

mcp_current_tool(Module, URI, Description, Options) :-
    tool(Module, URI, Description, Options).

%!  mcp_current_tool_raw_schema(?Module, ?Name, ?Schema) is nondet.

mcp_current_tool_raw_schema(Module, Name, Schema) :-
    tool_raw_schema(Module, Name, Schema).

                /*******************************
                *           DIRECTIVES         *
                *******************************/

%!  mcp_tool(:Name, +Description, +InputSchema) is det.
%
%   Declare an MCP _tool_ called  Name.   Description  is a short string
%   shown to the client. InputSchema is a   JSON Schema (as a dict) that
%   describes the parameters object passed to the handler.
%
%   This is normally used as a directive:
%
%       :- mcp_tool(name, "desc", #{...}).
%
%   The directive is processed by term_expansion/2  below and turns into
%   clauses for the dynamic  predicates   tool/4  and tool_raw_schema/3.
%   Reloading the source  file  therefore   replaces  the  registrations
%   cleanly (no duplicate accumulation, no stale   entries  if a tool is
%   removed).
%
%   The declaring module must provide a handler predicate Name/2:
%
%       handler(+Args:dict, -Content) is det.
%
%   The Content may be:
%
%     - A string or atom -- wrapped as a text content item
%     - A dict matching the MCP content schema
%     - A list of such dicts (multiple content items)
%
%   See library(mcp/content) for helpers that build content items.
%
%   For ad-hoc runtime registration use mcp_register_tool/4 directly.

mcp_tool(Module:Name, Description, Schema) :-
    mcp_register_tool(Module, Name, Description, Schema).

mcp_register_tool(Module, Name, Description, Schema) :-
    must_be_atom(Name),
    must_be_string(Description),
    json_compile_schema(Schema, Compiled, []),
    retractall(tool(Module, Name, _, _)),
    retractall(tool_raw_schema(Module, Name, _)),
    assertz(tool(Module, Name, Description, Compiled)),
    assertz(tool_raw_schema(Module, Name, Schema)),
    debug(mcp(register), 'Registered tool ~w:~w', [Module, Name]).

%!  mcp_resource(+URI, +Description, +Options) is det.
%
%   Declare a static MCP _resource_ identified by URI.  Options:
%
%     - name(+String)
%       Display name; defaults to URI.
%     - mime_type(+String)
%       Content MIME type; defaults to "text/plain".
%     - handler(:Goal)
%       Predicate Goal(+URI, -Content) returning content.
%       Defaults to a predicate of name `resource` taking URI and
%       Content in the declaring module.

mcp_resource(URI, Description, Options) :-
    mcp_register_resource(user, URI, Description, Options).

mcp_register_resource(Module, URI, Description, Options) :-
    must_be_string(URI),
    must_be_string(Description),
    retractall(resource(Module, URI, _, _)),
    assertz(resource(Module, URI, Description, Options)),
    debug(mcp(register), 'Registered resource ~w', [URI]).

%!  mcp_resource_template(+UriTemplate, +Description, +Options) is det.
%
%   Declare an RFC-6570 URI template describing   a  class of resources.
%   Options as for mcp_resource/3 plus:
%
%     - name(+String)
%     - mime_type(+String)
%     - handler(:Goal)
%       Predicate Goal(+URI, +Bindings:dict, -Content).
%
%   Normally    `:-    mcp_resource_template(Template,Desc,Opts)`     is
%   term-expanded.

mcp_resource_template(Module:Template, Description, Options) :-
    mcp_register_resource_template(Module, Template, Description, Options).

mcp_register_resource_template(Module, Template, Description, Options) :-
    must_be_string(Template),
    must_be_string(Description),
    retractall(resource_template(Module, Template, _, _)),
    assertz(resource_template(Module, Template, Description, Options)),
    debug(mcp(register), 'Registered resource template ~w', [Template]).

%!  mcp_prompt(:Name, +Description, +Arguments) is det.
%
%   Declare an MCP _prompt_ template.  Arguments is a list of
%   `#{name:String, description:String, required:Bool}` dicts.
%   The declaring module must provide a handler Name/2:
%
%       handler(+Args:dict, -Messages:list) is det.
%
%   where Messages is a list of `#{role:R, content:C}` dicts (see
%   library(mcp/content)).
%
%   Normally `:- mcp_prompt(Name,Desc,Args)` is term-expanded.


mcp_prompt(Module:Name, Description, Arguments) :-
    mcp_register_prompt(Module, Name, Description, Arguments).

mcp_register_prompt(Module, Name, Description, Arguments) :-
    must_be_atom(Name),
    must_be_string(Description),
    must_be(list, Arguments),
    retractall(prompt(Module, Name, _, _)),
    assertz(prompt(Module, Name, Description, Arguments)),
    debug(mcp(register), 'Registered prompt ~w:~w', [Module, Name]).

%!  mcp_server_info(+Dict) is det.
%
%   Declare  the  `serverInfo`  object  returned   by  the  `initialize`
%   handshake. Dict should contain at least `name` and `version`.
%
%   Normally `:- mcp_server_info(Dict)` is term-expanded.

mcp_server_info(Dict) :-
    must_be(dict, Dict),
    retractall(server_info(_)),
    assertz(server_info(Dict)).


                /*******************************
                *            DISPATCH          *
                *******************************/

:- use_module(library(mcp/lifecycle)).
:- use_module(library(mcp/tools)).
:- use_module(library(mcp/resources)).
:- use_module(library(mcp/prompts)).

:- meta_predicate
    mcp_dispatch(:, +, +).

%!  mcp_dispatch(:Stream, +Request, +Options) is det.
%
%   Handle a single decoded JSON-RPC Request from the MCP client.
%   Replies are written to Stream using json_rpc_send/3.  Requests
%   without an `id` are notifications and produce no reply.

mcp_dispatch(_:Stream, Request, Options) :-
    is_dict(Request),
    !,
    mcp_handle(Request, Stream, Options).
mcp_dispatch(_:Stream, Requests, Options) :-    % batch
    is_list(Requests),
    !,
    forall(member(R, Requests),
           mcp_handle(R, Stream, Options)).

mcp_handle(Request, Stream, Options) :-
    catch(mcp_handle_(Request, Stream, Options),
          Error,
          mcp_protocol_error(Error, Request, Stream, Options)).

mcp_handle_(Request, Stream, Options) :-
    #{ jsonrpc:"2.0", method:MethodS } :< Request,
    !,
    atom_string(Method, MethodS),
    Params = Request.get(params, #{}),
    Id     = Request.get(id, _),
    debug(mcp(rpc), 'request ~w id=~p params=~p', [Method, Id, Params]),
    mcp_method(Method, Params, Id, Stream, Options).
mcp_handle_(Request, Stream, Options) :-
    Id = Request.get(id, null),
    rpc_reply(Stream, #{jsonrpc:"2.0", id:Id,
                        error: #{code: -32600, message:"Invalid Request"}},
              Options).

mcp_protocol_error(Error, Request, Stream, Options) :-
    message_to_string(Error, Msg),
    (   Id = Request.get(id)
    ->  rpc_reply(Stream,
                  #{ jsonrpc:"2.0", id:Id,
                     error: #{ code: -32603,
                               message: "Internal error",
                               data: Msg } },
                  Options)
    ;   true
    ).


%!  mcp_method(+Method, +Params, ?Id, +Stream, +Options) is det.

mcp_method(initialize, Params, Id, Stream, Options) :- !,
    mcp_lifecycle:handle_initialize(Params, Result),
    rpc_reply(Stream, #{jsonrpc:"2.0", id:Id, result:Result}, Options).
mcp_method('notifications/initialized', _Params, _Id, _Stream, _Options) :- !.
mcp_method(ping, _Params, Id, Stream, Options) :- !,
    rpc_reply(Stream, #{jsonrpc:"2.0", id:Id, result: #{}}, Options).
mcp_method(shutdown, _Params, Id, Stream, Options) :- !,
    rpc_reply(Stream, #{jsonrpc:"2.0", id:Id, result:null}, Options).
mcp_method(exit, _Params, _Id, _Stream, _Options) :- !,
    halt(0).
mcp_method('tools/list', _Params, Id, Stream, Options) :- !,
    mcp_tools:list_tools(Tools),
    rpc_reply(Stream, #{jsonrpc:"2.0", id:Id, result: #{tools:Tools}}, Options).
mcp_method('tools/call', Params, Id, Stream, Options) :- !,
    mcp_tools:call_tool(Params, Result),
    rpc_reply(Stream, #{jsonrpc:"2.0", id:Id, result:Result}, Options).
mcp_method('resources/list', _Params, Id, Stream, Options) :- !,
    mcp_resources:list_resources(Resources),
    rpc_reply(Stream, #{jsonrpc:"2.0", id:Id,
                        result: #{resources:Resources}}, Options).
mcp_method('resources/templates/list', _Params, Id, Stream, Options) :- !,
    mcp_resources:list_resource_templates(Templates),
    rpc_reply(Stream, #{jsonrpc:"2.0", id:Id,
                        result: #{resourceTemplates:Templates}}, Options).
mcp_method('resources/read', Params, Id, Stream, Options) :- !,
    mcp_resources:read_resource(Params, Result),
    rpc_reply(Stream, #{jsonrpc:"2.0", id:Id, result:Result}, Options).
mcp_method('prompts/list', _Params, Id, Stream, Options) :- !,
    mcp_prompts:list_prompts(Prompts),
    rpc_reply(Stream, #{jsonrpc:"2.0", id:Id,
                        result: #{prompts:Prompts}}, Options).
mcp_method('prompts/get', Params, Id, Stream, Options) :- !,
    mcp_prompts:get_prompt(Params, Result),
    rpc_reply(Stream, #{jsonrpc:"2.0", id:Id, result:Result}, Options).
mcp_method(Method, _Params, Id, Stream, Options) :-
    nonvar(Id),
    !,
    rpc_reply(Stream,
              #{ jsonrpc:"2.0", id:Id,
                 error: #{ code: -32601,
                           message:"Method not found",
                           data: Method } },
              Options).
mcp_method(Method, _Params, _Id, _Stream, _Options) :-
    debug(mcp(rpc), 'Unknown notification ~w (ignored)', [Method]).


                /*******************************
                *            REPLY             *
                *******************************/

:- use_module(library(json_rpc_common), [json_rpc_send/3]).

%!  rpc_reply(+Stream, +Dict, +Options) is det.
%
%   Write Dict as a single-line JSON message terminated by a newline,
%   as required by the MCP stdio transport.

rpc_reply(Stream, Dict, Options) :-
    json_rpc_send(Stream, Dict, [width(0)|Options]),
    nl(Stream),
    flush_output(Stream).


                /*******************************
                *           UTILITIES          *
                *******************************/

:- use_module(library(error), [must_be/2]).

must_be_atom(X)   :- must_be(atom, X).
must_be_string(X) :- (string(X) ; atom(X)), !.
must_be_string(X) :- must_be(string, X).


                /*******************************
                *        SERVER INFO ACCESS    *
                *******************************/

%!  mcp_get_server_info(-Info:dict) is det.

mcp_get_server_info(Info) :-
    server_info(Info), !.
mcp_get_server_info(Info) :-
    mcp_server_info_hook(Info), !.
mcp_get_server_info(#{name:"swipl-mcp", version:"0.1.0"}).


                /*******************************
                *        TERM EXPANSION        *
                *******************************/

%   Expand registration directives into clauses of the dynamic
%   registry predicates (tool/4, tool_raw_schema/3, resource/4,
%   resource_template/4, prompt/4).  This way the clauses are
%   attached to the source file: on reload SWI replaces them
%   atomically, instead of the runtime-assertz pattern which has
%   to retract by (Module, Name) and silently leaves stale entries
%   if a tool is removed or renamed.

:- multifile
    system:term_expansion/2.

system:term_expansion((:- mcp_tool(Name, Description, Schema)),
                      [ mcp_server:tool(M, Name, Description, Compiled),
                        mcp_server:tool_raw_schema(M, Name, Schema)
                      ]) :-
    \+ current_prolog_flag(xref, true),
    prolog_load_context(module, M),
    must_be_atom(Name),
    must_be_string(Description),
    json_compile_schema(Schema, Compiled, []).

system:term_expansion((:- mcp_resource(URI, Description, Options)),
                      mcp_server:resource(M, URI, Description, Options)) :-
    \+ current_prolog_flag(xref, true),
    prolog_load_context(module, M),
    must_be_string(URI),
    must_be_string(Description).

system:term_expansion((:- mcp_resource_template(Template, Description, Options)),
                      mcp_server:resource_template(M, Template, Description, Options)) :-
    \+ current_prolog_flag(xref, true),
    prolog_load_context(module, M),
    must_be_string(Template),
    must_be_string(Description).

system:term_expansion((:- mcp_prompt(Name, Description, Arguments)),
                      mcp_server:prompt(M, Name, Description, Arguments)) :-
    \+ current_prolog_flag(xref, true),
    prolog_load_context(module, M),
    must_be_atom(Name),
    must_be_string(Description),
    must_be(list, Arguments).

system:term_expansion((:- mcp_server_info(Dict)),
                      [ mcp_server:server_info(Dict)
                      ]) :-
    \+ current_prolog_flag(xref, true),
    must_be(dict, Dict).

                /*******************************
                *    SERVER-INITIATED EVENTS   *
                *******************************/

%!  mcp_set_rpc_stream(+Stream) is det.
%
%   Record the JSON-RPC output stream  so   that  mcp_notify/2  can send
%   server-initiated  notifications  outside  of   the  request/response
%   cycle.  Called  by  library(mcp/stdio)  after  the  stream  pair  is
%   established.

mcp_set_rpc_stream(Stream) :-
    retractall(rpc_stream(_)),
    assertz(rpc_stream(Stream)).

%!  mcp_notify(+Method, +Params) is det.
%
%   Send a JSON-RPC 2.0 notification (no   id)  to the connected client.
%   Dispatches to whichever transports are currently active:
%
%     1. If an rpc_stream/1 is registered (stdio transport), write
%        the notification to it directly.
%     2. Then call every mcp_transport_notify_hook/2 clause -- the
%        HTTP+SSE transport supplies one that fans the notification
%        out over each live session's SSE stream.
%
%   Either or both may be active in  the same process. Silently succeeds
%   when nothing is connected (e.g. during unit tests).

:- multifile mcp_transport_notify_hook/2.

mcp_notify(Method, Params) :-
    (   rpc_stream(Stream)
    ->  catch(rpc_reply(Stream,
                        #{jsonrpc:"2.0", method:Method, params:Params},
                        []),
              error(_,_), true)
    ;   true
    ),
    forall(catch(mcp_transport_notify_hook(Method, Params),
                 error(_,_), true),
           true).
