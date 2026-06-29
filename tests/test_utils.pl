/*  Shared helpers for the PLUnit test suites in tests/.

    Bring in via:

        :- use_module(test_utils, [tool_call/3, ...]).

    swipl resolves the bare module name against the directory of the
    loading file, so the import works from any test_*.pl in this
    directory without a file-search-path tweak.
*/

:- module(test_utils,
          [ tool_call/3,                 % +Name, +Args, -Text
            dispatch/2,                  % +Request, -Reply
            stop_target/1,               % +Name (best-effort)
            with_temp_file/3             % +Content, -File, :Goal
          ]).
:- use_module(library(mcp/server), [mcp_dispatch/3]).
:- use_module(library(json), [atom_json_dict/3]).

:- meta_predicate
    with_temp_file(+, -, 0).

%!  tool_call(+Name:text, +Args:dict, -Text:string) is det.
%
%   Dispatch a tools/call request for Name with Args and extract the
%   single text item from the result content list.  All MCP tools in
%   this pack return either a string or a single text content dict,
%   so this is the right shape for every test that calls a tool.

tool_call(Name, Args, Text) :-
    dispatch(#{ jsonrpc:"2.0", id:1, method:"tools/call",
                params: #{name:Name, arguments:Args} },
             Reply),
    [Item] = Reply.result.content,
    Text = Item.text.

%!  dispatch(+Request:dict, -Reply:dict) is det.
%
%   Run the MCP dispatcher against an in-memory string output and
%   decode the single JSON reply that lands in it.  The `user:`
%   module qualifier on the stream is purely formal -- mcp_dispatch/3
%   discards it (its meta-arg is `?`, not a goal).

dispatch(Request, Reply) :-
    with_output_to(
        string(Data),
        mcp_dispatch(user:current_output, Request, [])),
    atom_json_dict(Data, Reply, [value_string_as(string)]).

%!  stop_target(+Name:text) is det.
%
%   Best-effort target_stop -- ignores `error(_,_)` exceptions so the
%   cleanup hook of an already-failed test never raises.

stop_target(Name) :-
    catch(tool_call("target_stop", #{target:Name}, _),
          error(_,_), true).

%!  with_temp_file(+Content:text, -File:atom, :Goal) is det.
%
%   Write Content into a fresh UTF-8 tmp file, call Goal with File
%   bound to the path, delete the file on the way out (even if Goal
%   throws).  File is also unbound on the way in -- it gets the path
%   produced by tmp_file_stream/3.

with_temp_file(Content, File, Goal) :-
    setup_call_cleanup(
        ( tmp_file_stream(utf8, File, Stream),
          write(Stream, Content),
          close(Stream)
        ),
        Goal,
        catch(delete_file(File), error(_,_), true)).
