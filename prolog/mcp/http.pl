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

:- module(mcp_http, []).
:- use_module(library(mcp/server), [mcp_dispatch/3]).
:- use_module(library(http/thread_httpd), [http_server/2, http_spawn/2]).
:- use_module(library(http/http_dispatch), [http_handler/3, http_404/2]).
:- use_module(library(http/http_json),
              [http_read_json_dict/2, reply_json_dict/2]).
:- use_module(library(http/sse), [sse_open/1, sse_send/1, sse_comment/1]).
:- use_module(library(option), [option/2, option/3]).
:- use_module(library(uuid), [uuid/1]).
:- use_module(library(json), [json_write_dict/3]).

/** <module> MCP HTTP+SSE transport

Implements the 2024-11-05 MCP HTTP+SSE transport.

Two endpoints:

  - POST <base>/messages
      Client sends a single JSON-RPC 2.0 request.  The server runs
      it through mcp_dispatch/3, captures the synchronous reply into
      a memory stream, and returns it as the HTTP response body.

  - GET <base>/sse
      Long-lived Server-Sent Events stream.  Server-initiated
      notifications (everything that goes through mcp_notify/2) are
      delivered here, one SSE event per JSON-RPC notification.

Sessions are identified by the Mcp-Session-Id HTTP header.  The
server mints a new id on the first POST that lacks the header and
returns it in the response's Mcp-Session-Id.  Clients copy that
value onto every subsequent POST and the GET.

Public API:

  - mcp_http_run(+Options) starts the server and returns.

  - mcp_http_wait_forever/0 blocks the current thread on an
    impossible message_queue read so the example loader can stay
    alive while the HTTP worker threads do the work.
*/

:- dynamic
    mcp_session/2.                      % SessionId, Queue

%  library(pldoc) (pulled in transitively by mcp/servers/prolog_help
%  for manual_section's renderer) declares HTTP handlers under
%  the path aliases `pldoc`, `pldoc_man` and `pldoc_pkg`.  Those
%  aliases are normally registered when one loads library(doc_http)
%  to host a pldoc web frontend, which we do not.  Provide the same
%  declarations here so http_dispatch can resolve the aliases at
%  worker boot; the pldoc handlers themselves remain unused.

:- multifile http:location/3.
http:location(mcp,       root(mcp),         [priority(10)]).
% Hide PlDoc
http:location(pldoc,     root(pldoc),       [priority(-10)]).
http:location(pldoc_man, pldoc(refman),     [priority(-10)]).
http:location(pldoc_pkg, pldoc(package),    [priority(-10)]).

%  Catch-all 404 under /pldoc/* so the pldoc handlers, which we
%  loaded only for their renderer, do not accidentally serve.
%  hide_children(true) masks every more-specific pldoc handler the
%  imported pldoc modules also register, so we don't have to
%  http_delete_handler them and the masking survives reloads
%  cleanly.
:- http_handler(root(pldoc), http_404([]),
                [prefix, hide_children(true), priority(10)]).

:- http_handler(mcp(messages), handle_post, [ method(post),
                                              id(mcp_http_post)
                                            ]).
:- http_handler(mcp(sse),      handle_sse,  [ method(get),
                                              id(mcp_http_sse),
                                              spawn([]),
                                              time_limit(infinite)
                                            ]).
:- http_handler(root(mcp),     handle_mcp,  [ methods([get,post]),
                                              id(mcp_http_streamable_sse)
                                            ]).

%!  handle_mcp(+Request)
%
%   Handle POST and SSE requests on the same location.

handle_mcp(Request) :-
    option(method(post), Request),
    !,
    handle_post(Request).
handle_mcp(Request) :-
    option(method(get), Request),
    http_spawn(handle_sse(Request), []).


                /*******************************
                *      POST /messages          *
                *******************************/

handle_post(Request) :-
    catch(http_read_json_dict(Request, JsonReq), Err,
          ( reply_bad_request(Err), fail )),
    !,
    ensure_session(Request, SessionId),
    %  Run the dispatcher with a memory stream that captures the
    %  synchronous reply.  mcp_dispatch writes one JSON object per
    %  request followed by a newline; we read the whole buffer back
    %  and forward it verbatim.
    with_output_to(string(RawReply),
                   mcp_dispatch(current_output, JsonReq,
                                [mcp_session(SessionId)])),
    %  Send the reply with the session header so the client knows
    %  which id to use on the SSE GET.
    format('Mcp-Session-Id: ~w~n', [SessionId]),
    format('Content-Type: application/json; charset=UTF-8~n~n'),
    write(RawReply).
handle_post(_Request).
    %  Already replied with an error in the catch above.

reply_bad_request(Err) :-
    message_to_string(Err, Msg),
    format('Status: 400 Bad Request~n'),
    format('Content-Type: application/json; charset=UTF-8~n~n'),
    reply_json_dict(#{ jsonrpc:"2.0",
                       error: #{ code: -32700,
                                 message: "Parse error",
                                 data: Msg } },
                    [width(0)]).

ensure_session(Request, SessionId) :-
    (   memberchk(mcp_session_id(SessionId), Request)
    ->  ensure_session_record(SessionId)
    ;   uuid(SessionId),
        ensure_session_record(SessionId)
    ).

ensure_session_record(SessionId) :-
    (   mcp_session(SessionId, _Q)
    ->  true
    ;   message_queue_create(Q),
        assertz(mcp_session(SessionId, Q))
    ).


                /*******************************
                *        GET /sse              *
                *******************************/

handle_sse(Request) :-
    (   memberchk(mcp_session_id(SessionId), Request),
        mcp_session(SessionId, Q)
    ->  true
    ;   format('Status: 400 Bad Request~n'),
        format('Content-Type: text/plain~n~n'),
        format('Missing or unknown Mcp-Session-Id'),
        fail
    ),
    !,
    sse_open([retry(5)]),
    %  Send an opening comment so the client sees data flowing
    %  even if no notification fires for a while.
    catch(sse_comment("mcp/sse open"), error(_,_), true),
    sse_loop(Q, SessionId).
handle_sse(_Request).

sse_loop(Q, SessionId) :-
    %  15 s heartbeat keeps idle reverse proxies from killing the
    %  stream.  thread_get_message/3 with timeout/1 *fails* on
    %  expiry, which is the heartbeat trigger.
    (   thread_get_message(Q, Event, [timeout(15)])
    ->  send_event(Event, Q, SessionId)
    ;   send_event(keep_alive, Q, SessionId)
    ).

send_event(keep_alive, Q, SessionId) :- !,
    (   catch(sse_comment("keep-alive"), error(_,_), fail)
    ->  sse_loop(Q, SessionId)
    ;   end_session(Q, SessionId)
    ).
send_event(Event, Q, SessionId) :-
    (   catch(sse_send(Event), error(_,_), fail)
    ->  sse_loop(Q, SessionId)
    ;   end_session(Q, SessionId)
    ).

%  Stream closed by the client -- retract the session record so the
%  notify hook stops trying to enqueue to a dead queue.
end_session(Q, SessionId) :-
    retractall(mcp_session(SessionId, Q)),
    catch(message_queue_destroy(Q), error(_,_), true).


                /*******************************
                *      NOTIFICATION HOOK       *
                *******************************/

:- use_module(library(json), [json_write_dict/3]).

:- multifile mcp_server:mcp_transport_notify_hook/2.

mcp_server:mcp_transport_notify_hook(Method, Params) :-
    Body = #{jsonrpc:"2.0", method:Method, params:Params},
    with_output_to(string(JsonText),
                   json_write_dict(current_output, Body, [width(0)])),
    Event = #{event:"message", data:JsonText},
    forall(mcp_session(_SessionId, Q),
           thread_send_message(Q, Event)).


%  http_read_request/2 canonicalises HTTP header names by
%  lowercasing and turning `-` into `_`, so the `Mcp-Session-Id`
%  request header arrives as `mcp_session_id(Value)` in the
%  Request list -- nothing else needed here.
