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

:- module(mcp_stdio,
          [ mcp_stdio_run/0
          ]).
:- use_module(library(mcp/server), [mcp_dispatch/3, mcp_set_rpc_stream/1]).
:- use_module(library(json), [json_read_dict/3]).
:- use_module(library(debug), [debug/3]).

/** <module> stdio transport for MCP servers

Reads  newline-delimited  JSON-RPC  requests  from    stdin  and  writes
responses to stdout. Before entering the loop the original stdout stream
is captured, Prolog's `user_output`  is  bound   to  a  null  stream and
`user_error` is bound to a null stream   if  writing an initial feedback
message fails.

Typical use in an application file:

    :- module(my_server, []).
    :- use_module(library(mcp/server)).
    :- use_module(library(mcp/stdio)).

    :- mcp_tool(...).

    :- initialization(mcp_stdio_run, main).
*/

%!  mcp_stdio_run is det.
%
%   Run the MCP server on stdin/stdout until EOF.

mcp_stdio_run :-
    set_prolog_flag(verbose, silent),
    current_input(StdIn),
    current_output(StdOut),
    set_stream(StdIn,  encoding(utf8)),
    set_stream(StdOut, encoding(utf8)),
    %  Make a stream pair that we will use for the JSON-RPC channel.
    stream_pair(RpcStream, StdIn, StdOut),
    %  Stash for server-initiated notifications (mcp_notify/2).
    mcp_set_rpc_stream(RpcStream),
    redirect_user_io_to_null,
    catch(run_loop(RpcStream),
          Error,
          (   print_message(error, Error),
              halt(1)
          )),
    halt(0).

%!  redirect_user_io_to_null is det.
%
%   Bind user_input/user_output/user_error to null   streams  so nothing
%   accidentally writes to stdout (which IS the RPC channel) and so that
%   print_message/2 never short-circuits on a   stream-error flag, which
%   it would do if some earlier  write   to  user_error  failed. See the
%   second print_message/2 clause in boot/messages.pl   --  it skips ALL
%   hook dispatch when the destination has error(true).

redirect_user_io_to_null :-
    open_null_stream(NullOut),
    set_stream(NullOut, alias(user_output)),
    (   catch(( format(user_error, "Connected\n", []),
                flush_output(user_error)
              ),
              error(_,_),
              fail)
    ->  true
    ;   open_null_stream(NullErr),
        set_stream(NullErr, alias(user_error))
    ).

run_loop(Stream) :-
    json_read_dict(Stream, Request,
                   [ end_of_file(end_of_file),
                     value_string_as(string)
                   ]),
    (   Request == end_of_file
    ->  true
    ;   debug(mcp(stdio), 'received: ~p', [Request]),
        catch(mcp_dispatch(user:Stream, Request, []),
              Error,
              print_message(error, Error)),
        run_loop(Stream)
    ).
