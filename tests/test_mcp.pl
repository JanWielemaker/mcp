/*  Smoke tests for the MCP framework.

    Drives the dispatcher by handing it decoded request dicts and
    inspecting the reply written to a memory stream.

    Run as:

        swipl -g 'test_mcp,halt' tests/test_mcp.pl
*/

:- module(test_mcp,
          [ test_mcp/0
          ]).
:- use_module(library(mcp/server)).
:- use_module(library(plunit)).
:- use_module(library(debug)).
:- use_module(library(lists)).
:- use_module(test_utils, [dispatch/2]).

:- mcp_tool(
       echo,
       "Echo the input message.",
       #{ type:object,
          properties: #{msg: #{type:string}},
          required: [msg]
        }).

echo(Args, Args.msg).

:- mcp_tool(
       add,
       "Add two integers.",
       #{ type:object,
          properties: #{ a: #{type:integer}, b: #{type:integer} },
          required: [a, b]
        }).

add(#{a:A, b:B}, Result) :-
    Sum is A + B,
    format(string(Result), "~w", [Sum]).

test_mcp :-
    run_tests([mcp]).


:- begin_tests(mcp).

test(initialize) :-
    mcp_server_info(#{name:"test", version:"0.1"}),
    dispatch(#{ jsonrpc:"2.0", id:1, method:"initialize",
                params: #{protocolVersion:"2024-11-05",
                          capabilities: #{},
                          clientInfo: #{name:"tester", version:"0"}} },
             Reply),
    Name = Reply.result.serverInfo.name,
    assertion(Name == "test").

test(tools_list) :-
    dispatch(#{jsonrpc:"2.0", id:2, method:"tools/list"},
             Reply),
    Tools = Reply.result.tools,
    findall(N, ( member(T, Tools), N = T.name ), Names0),
    sort(Names0, Names),
    assertion(Names == ["add","echo"]).

test(tools_call_echo) :-
    dispatch(#{ jsonrpc:"2.0", id:3, method:"tools/call",
                params: #{name:"echo", arguments: #{msg:"hi there"}} },
             Reply),
    [Item] = Reply.result.content,
    assertion(Item.text == "hi there"),
    assertion(Reply.result.isError == false).

test(tools_call_add) :-
    dispatch(#{ jsonrpc:"2.0", id:4, method:"tools/call",
                params: #{name:"add", arguments: #{a:3, b:4}} },
             Reply),
    [Item] = Reply.result.content,
    assertion(Item.text == "7").

test(tools_call_bad_args) :-
    dispatch(#{ jsonrpc:"2.0", id:5, method:"tools/call",
                params: #{name:"add", arguments: #{a:"oops", b:1}} },
             Reply),
    %  Either a JSON-RPC error reply or a tool reply with isError:true.
    (   _ = Reply.get(error)
    ->  true
    ;   true == Reply.result.get(isError)
    ->  true
    ;   fail
    ).

test(method_not_found) :-
    dispatch(#{jsonrpc:"2.0", id:6, method:"nope/list"},
             Reply),
    Code = Reply.error.code,
    assertion(Code == -32601).

test(unknown_tool) :-
    dispatch(#{ jsonrpc:"2.0", id:7, method:"tools/call",
                params: #{name:"missing", arguments: #{}} },
             Reply),
    (   _ = Reply.get(error)
    ->  true
    ;   true == Reply.result.get(isError)
    ).

:- end_tests(mcp).
