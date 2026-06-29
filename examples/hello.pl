/*  Minimal MCP server example -- echoes its input.

    Run as:

        swipl examples/hello.pl

    The server speaks MCP on stdin/stdout.
*/

:- module(hello_server, []).
:- use_module(library(mcp/server)).
:- use_module(library(mcp/stdio)).

:- mcp_server_info(#{name:"hello", version:"0.1.0"}).

:- mcp_tool(
       echo,
       "Echo the input message.",
       #{ type: object,
          properties: #{ msg: #{type:string} },
          required: [msg]
        }).

echo(Args, Args.msg).

:- mcp_tool(
       add,
       "Add two integers.",
       #{ type: object,
          properties: #{ a: #{type:integer},
                         b: #{type:integer} },
          required: [a, b]
        }).

add(#{a:A, b:B}, Text) :-
    Sum is A + B,
    format(string(Text), "~w", [Sum]).

:- initialization(mcp_stdio_run, main).
