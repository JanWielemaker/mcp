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

:- module(mcp_resources,
          [ list_resources/1,           % -Resources
            list_resource_templates/1,  % -Templates
            read_resource/2             % +Params, -Result
          ]).
:- use_module(library(option), [option/2, option/3]).
:- use_module(library(lists), [append/3]).
:- use_module(server, [mcp_current_resource/4, mcp_current_resource_template/4]).

/** <module> resources/list, resources/read, resources/templates/list

A static resource is matched by exact URI.  A resource template is an
RFC-6570 URI template with `{var}` placeholders.  On `resources/read`
we first try to match a static URI, then any template; if the template
matches, the parsed bindings are passed to the handler.

Handler contracts:

    HandlerStatic(+URI, -Content)
    HandlerTemplate(+URI, +Bindings:dict, -Content)

Content may be a single resource dict or a list of them.
*/

%!  list_resources(-Resources) is det.

list_resources(Resources) :-
    findall(R, current_resource(R), Resources).

current_resource(R) :-
    mcp_current_resource(_Module, URI, Description, Options),
    (   option(name(Name), Options) -> true ; Name = URI ),
    (   option(mime_type(Mime), Options) -> true ; Mime = "text/plain" ),
    R = #{uri:URI, name:Name, description:Description, mimeType:Mime}.

%!  list_resource_templates(-Templates) is det.

list_resource_templates(Templates) :-
    findall(T, current_template(T), Templates).

current_template(T) :-
    mcp_current_resource(_Module, Tmpl, Description, Options),
    option(name(Name), Options, Tmpl),
    option(mime_type(Mime), Options, "text/plain"),
    T = #{uriTemplate:Tmpl, name:Name,
          description:Description, mimeType:Mime}.

%!  read_resource(+Params, -Result) is det.
%
%   Params is `#{uri:URI}`.

read_resource(Params, #{contents:Contents}) :-
    URI = Params.get(uri),
    (   match_static(URI, Module, Options)
    ->  call_static(Module, URI, Options, Contents)
    ;   match_template(URI, Module, Tmpl, Options, Bindings)
    ->  call_template(Module, URI, Bindings, Tmpl, Options, Contents)
    ;   throw(mcp_error(-32602, "Unknown resource", #{uri:URI}))
    ).

match_static(URI, Module, Options) :-
    mcp_current_resource(Module, URI, _Desc, Options).

call_static(Module, URI, Options, Contents) :-
    option(handler(GoalSpec), Options, resource),
    qualify(Module, GoalSpec, Goal),
    call(Goal, URI, Raw),
    to_resource_list(Raw, URI, Options, Contents).

match_template(URI, Module, Tmpl, Options, Bindings) :-
    mcp_current_resource_template(Module, Tmpl, _Desc, Options),
    uri_template_match(Tmpl, URI, Bindings),
    !.

call_template(Module, URI, Bindings, _Tmpl, Options, Contents) :-
    option(handler(GoalSpec), Options, resource),
    qualify(Module, GoalSpec, Goal),
    call(Goal, URI, Bindings, Raw),
    to_resource_list(Raw, URI, Options, Contents).

qualify(_, M:G, M:G) :- !.
qualify(Module, G, Module:G).

to_resource_list(List, _URI, _Options, List) :-
    is_list(List), !.
to_resource_list(Dict, _URI, _Options, [Dict]) :-
    is_dict(Dict), !.
to_resource_list(Text, URI, Options, [R]) :-
    (   string(Text) ; atom(Text) ),
    !,
    (   string(Text) -> S = Text ; atom_string(Text, S) ),
    (   option(mime_type(Mime), Options) -> true ; Mime = "text/plain" ),
    R = #{uri:URI, mimeType:Mime, text:S}.


                /*******************************
                *       URI TEMPLATE MATCH     *
                *******************************/

%!  uri_template_match(+Template, +URI, -Bindings) is semidet.
%
%   Match an RFC-6570 level-1 URI template (`{var}` placeholders only)
%   against URI.  Returns Bindings as a dict from variable name to
%   matched substring.  Matching is greedy and constrained per
%   RFC-6570 expansion rules for level-1 (no reserved character
%   expansion, no operators, percent-decoded).

uri_template_match(Template, URI, Bindings) :-
    string_codes(Template, TCodes),
    string_codes(URI, UCodes),
    phrase(template_pattern(Pairs), TCodes),
    match_pattern(Pairs, UCodes, Assoc),
    dict_pairs(Bindings, _, Assoc).

template_pattern([literal(LitCodes)|T]) -->
    literal(LitCodes),
    { LitCodes \== [] },
    !,
    template_pattern(T).
template_pattern([var(Name)|T]) -->
    "{", var_name(NameCodes), "}",
    !,
    { atom_codes(Name, NameCodes) },
    template_pattern(T).
template_pattern([]) --> [].

literal([C|T]) --> [C], { C \== 0'{ }, literal(T).
literal([]) --> [].

var_name([C|T]) --> [C], { C \== 0'} }, var_name(T).
var_name([]) --> [].

match_pattern([], [], []).
match_pattern([literal(L)|Rest], Codes, Assoc) :-
    append(L, Tail, Codes),
    match_pattern(Rest, Tail, Assoc).
match_pattern([var(Name)|Rest], Codes, [Name-Value|Assoc]) :-
    var_split(Codes, ValueCodes, Tail),
    \+ memberchk(0'/, ValueCodes),          % level-1: vars are slash-free
    string_codes(Value, ValueCodes),
    match_pattern(Rest, Tail, Assoc).

var_split(Codes, [], Codes).
var_split([H|T], [H|V], Tail) :-
    var_split(T, V, Tail).
