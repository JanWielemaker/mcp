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

:- module(mcp_content,
          [ mcp_text/2,                 % +Text, -Item
            mcp_image/3,                % +Base64Data, +MimeType, -Item
            mcp_resource_link/2,        % +URI, -Item
            mcp_text_resource/3,        % +URI, +Text, -Resource
            mcp_blob_resource/4,        % +URI, +Base64Data, +MimeType, -Resource
            mcp_to_content_list/2       % +RawContent, -ContentList
          ]).

/** <module> Helpers to build MCP content and resource objects.

These predicates produce the dicts described in the MCP specification
for tool results and resource reads.  Tool handlers may return any
combination of the following, which mcp_to_content_list/2 will
normalize to a list of content dicts:

  - a string or atom -- treated as text
  - a single content dict
  - a list of content dicts
*/

%!  mcp_text(+Text, -Item) is det.
mcp_text(Text, #{type:"text", text:Text}).

%!  mcp_image(+Base64Data, +MimeType, -Item) is det.
mcp_image(Data, Mime, #{type:"image", data:Data, mimeType:Mime}).

%!  mcp_resource_link(+URI, -Item) is det.
mcp_resource_link(URI, #{type:"resource", resource: #{uri:URI}}).

%!  mcp_text_resource(+URI, +Text, -Resource) is det.
mcp_text_resource(URI, Text,
                  #{uri:URI, mimeType:"text/plain", text:Text}).

%!  mcp_blob_resource(+URI, +Base64Data, +MimeType, -Resource) is det.
mcp_blob_resource(URI, Data, Mime,
                  #{uri:URI, mimeType:Mime, blob:Data}).

%!  mcp_to_content_list(+Raw, -List) is det.
%
%   Normalize a tool handler return value into a list of MCP content
%   dicts.

mcp_to_content_list(Raw, List) :-
    string(Raw),
    !,
    mcp_text(Raw, Item),
    List = [Item].
mcp_to_content_list(Raw, List) :-
    atom(Raw),
    !,
    atom_string(Raw, S),
    mcp_text(S, Item),
    List = [Item].
mcp_to_content_list(Raw, List) :-
    is_dict(Raw),
    !,
    List = [Raw].
mcp_to_content_list(Raw, Raw) :-
    is_list(Raw),
    !.
mcp_to_content_list(Raw, [Item]) :-
    format(string(S), '~p', [Raw]),
    mcp_text(S, Item).
