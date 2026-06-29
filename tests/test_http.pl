/*  Integration tests for library(mcp/http).

    Boots mcp_http_run/1 on an ephemeral port (the OS picks one via
    port(Var)), then drives it from the test process using
    library(http/http_open) -- the same code path Claude Code and any
    other HTTP client would take.

    Run as:

        swipl -g 'test_http,halt' tests/test_http.pl
*/

:- module(test_http,
          [ test_http/0
          ]).
:- use_module(library(mcp/server)).
:- use_module(library(mcp/http)).
:- use_module(library(plunit)).
:- use_module(library(debug), [assertion/1]).
:- use_module(library(http/http_open), [http_open/3]).
:- use_module(library(http/http_server), [http_server/1, http_stop_server/2]).
:- use_module(library(json), [atom_json_dict/3, json_write_dict/3]).
:- use_module(library(lists), [append/3]).

:- mcp_server_info(#{name:"test-http", version:"0.0"}).

%  A trivial tool registered against THIS module so tools/list /
%  tools/call have something to find while the HTTP transport runs
%  inside the same process.

:- mcp_tool(http_echo,
            "Echo the input message.",
            #{ type: object,
               properties: #{ msg: #{ type: string } },
               required: [msg]
             }).

http_echo(Args, Args.msg).

test_http :-
    run_tests([http]).

:- dynamic test_port/1.

start_test_server :-
    %  port(Var) asks tcp_bind to pick a free port and binds Var to
    %  it; we read it back via http_server's option list.
    http_server([port(Port), silent(true)]),
    assertz(test_port(Port)).

stop_test_server :-
    forall(retract(test_port(P)),
           catch(http_stop_server(P, []), error(_,_), true)).


:- begin_tests(http,
               [ setup(start_test_server),
                 cleanup(stop_test_server)
               ]).

test(initialize_returns_serverinfo) :-
    test_port(Port),
    rpc_post(Port, _NoSid,
             #{ jsonrpc: "2.0", id: 1, method: "initialize",
                params:
                  #{ protocolVersion: "2024-11-05",
                     capabilities: #{},
                     clientInfo: #{ name: "test", version: "0" }
                   }
              },
             SessionId, Reply),
    %  Server should mint a session id (a UUID atom) on the first POST.
    assertion(atom(SessionId)),
    assertion(SessionId \== ''),
    %  And serverInfo should round-trip our mcp_server_info dict.
    assertion(Reply.result.serverInfo.name == "test-http").

test(tools_call_echo) :-
    test_port(Port),
    rpc_post(Port, _,
             #{ jsonrpc: "2.0", id: 2, method: "tools/call",
                params:
                  #{ name: "http_echo",
                     arguments: #{ msg: "hi from http" }
                   }
              },
             _Sid, Reply),
    [Item] = Reply.result.content,
    assertion(Item.text == "hi from http"),
    assertion(false == Reply.result.isError).

test(session_id_persists_across_posts) :-
    test_port(Port),
    %  First request: server mints a session.
    rpc_post(Port, _NoSid0,
             #{ jsonrpc: "2.0", id: 3, method: "initialize",
                params:
                  #{ protocolVersion: "2024-11-05",
                     capabilities: #{},
                     clientInfo: #{ name: "t", version: "0" }
                   }
              },
             Sid1, _),
    %  Second request reusing it should get the SAME id echoed back.
    rpc_post(Port, Sid1,
             #{ jsonrpc: "2.0", id: 4, method: "tools/list" },
             Sid2, _),
    assertion(Sid1 == Sid2).

test(unknown_method_returns_jsonrpc_error) :-
    test_port(Port),
    rpc_post(Port, _,
             #{ jsonrpc: "2.0", id: 5, method: "nope/list" },
             _, Reply),
    assertion(-32601 == Reply.error.code).

test(sse_requires_session_header) :-
    %  GET /mcp/sse without a Mcp-Session-Id header should be a 400.
    test_port(Port),
    format(atom(URL), "http://localhost:~w/mcp/sse", [Port]),
    catch(http_open(URL, In, [status_code(Status)]),
          error(_,_),
          Status = -1),
    (   nonvar(In) -> close(In) ; true ),
    assertion(Status == 400).

test(notify_enqueues_onto_session_queue) :-
    %  Mint a session via POST, then call mcp_notify/2 and confirm
    %  the multifile mcp_transport_notify_hook/2 in mcp/http fanned
    %  the notification onto the session's message queue (the same
    %  queue the SSE handler reads from to write SSE events).
    test_port(Port),
    rpc_post(Port, _,
             #{ jsonrpc: "2.0", id: 6, method: "initialize",
                params:
                  #{ protocolVersion: "2024-11-05",
                     capabilities: #{},
                     clientInfo: #{ name: "t", version: "0" }
                   }
              },
             Sid, _),
    mcp_notify('notifications/test', #{x:1}),
    mcp_http:mcp_session(Sid, Q),
    thread_get_message(Q, Event, [timeout(2)]),
    assertion(is_dict(Event)),
    assertion("message" == Event.event),
    atom_json_dict(Event.data, Decoded, [value_string_as(string)]),
    assertion("notifications/test" == Decoded.method),
    assertion(1 == Decoded.params.x).

:- end_tests(http).


%!  rpc_post(+Port, ?InSid, +Request, -OutSid, -Reply) is det.
%
%   POST Request as JSON to /mcp/messages.  If InSid is unbound, no
%   Mcp-Session-Id header is sent (the first request); otherwise it
%   is forwarded verbatim and the server should echo it.  OutSid is
%   bound to the Mcp-Session-Id of the response.

rpc_post(Port, InSid, Request, OutSid, Reply) :-
    with_output_to(string(JsonText),
                   json_write_dict(current_output, Request, [width(0)])),
    format(atom(URL), "http://localhost:~w/mcp/messages", [Port]),
    request_headers(InSid, ReqHeaders),
    append(ReqHeaders,
           [ method(post),
             post(atom('application/json', JsonText)),
             header(mcp_session_id, OutSid)
           ],
           Options),
    setup_call_cleanup(
        http_open(URL, In, Options),
        read_string(In, _Len, Body),
        close(In)),
    atom_json_dict(Body, Reply, [value_string_as(string)]).

request_headers(InSid, []) :- var(InSid), !.
request_headers(InSid,
                [request_header('Mcp-Session-Id'=InSid)]).
