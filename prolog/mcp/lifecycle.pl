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

:- module(mcp_lifecycle,
          [ handle_initialize/2         % +Params, -Result
          ]).
:- use_module(library(debug), [debug/3]).
:- use_module(server, [mcp_protocol_version/1, mcp_get_server_info/1]).

/** <module> MCP lifecycle (initialize handshake)
*/

%!  handle_initialize(+Params, -Result) is det.
%
%   Handle the `initialize` request.  Reports the protocol version we
%   speak, our capability set, and serverInfo.  Capability dicts are
%   intentionally minimal -- presence of a key indicates support.

handle_initialize(Params, Result) :-
    mcp_protocol_version(MyVersion),
    ClientVersion = Params.get(protocolVersion, MyVersion),
    debug(mcp(lifecycle),
          'initialize: client=~w server=~w',
          [ClientVersion, MyVersion]),
    mcp_get_server_info(ServerInfo),
    Result = #{ protocolVersion: MyVersion,
                serverInfo: ServerInfo,
                capabilities:
                    #{ tools:     #{ listChanged: true },
                       resources: #{ listChanged: false,
                                     subscribe:   false },
                       prompts:   #{ listChanged: false }
                     }
              }.
