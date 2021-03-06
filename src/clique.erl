%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(clique).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([register/1,
         register_node_finder/1,
         unregister_node_finder/0,
         register_command/4,
         unregister_command/1,
         register_config/2,
         unregister_config/1,
         register_formatter/2,
         unregister_formatter/1,
         register_writer/2,
         unregister_writer/1,
         register_config_whitelist/2,
         unregister_config_whitelist/2,
         register_usage/2,
         unregister_usage/1,
         run/1,
         print/2]).

-type err() :: {error, term()}.

-spec register([module()]) -> ok.
register(Modules) ->
    _ = [M:register_cli() || M <- Modules],
    ok.

%% @doc RPC calls when using the --all flag need a list of nodes to contact.
%% However, using nodes() only provides currently connected nodes. We want to
%% also report an alert for nodes that are not currently available instead of just
%% ignoring them. This allows the caller to define how we find the list of
%% cluster member nodes.
-spec register_node_finder(fun()) -> true.
register_node_finder(Fun) ->
    clique_nodes:register(Fun).

-spec unregister_node_finder() -> true.
unregister_node_finder() ->
    clique_nodes:unregister().

%% @doc Register configuration callbacks for a given config key
-spec register_config([string()], fun()) -> true.
register_config(Key, Callback) ->
    clique_config:register(Key, Callback).

-spec unregister_config([string()]) -> true.
unregister_config(Key) ->
    clique_config:unregister(Key).

%% @doc Register a configuration formatter for a given config key
-spec register_formatter([string()], fun()) -> true.
register_formatter(Key, Callback) ->
    clique_config:register_formatter(Key, Callback).

-spec unregister_formatter([string()]) -> true.
unregister_formatter(Key) ->
    clique_config:unregister_formatter(Key).

%% @doc Register a module for writing output in a specific format
-spec register_writer(string(), module()) -> true.
register_writer(Name, Module) ->
    clique_writer:register(Name, Module).

-spec unregister_writer(string()) -> true.
unregister_writer(Name) ->
    clique_writer:unregister(Name).

%% @doc Register a list of configuration variables that are settable.
%% Clique disallows setting of all config variables by default. They must be in
%% whitelist to be settable.
-spec register_config_whitelist([string()], atom()) -> ok | {error, {invalid_config_keys, [string()]}}.
register_config_whitelist(SettableKeys, App) ->
    clique_config:whitelist(SettableKeys, App).

-spec unregister_config_whitelist([string()], atom()) -> ok | {error, {invalid_config_keys, [string()]}}.
unregister_config_whitelist(SettableKeys, App) ->
    clique_config:unwhitelist(SettableKeys, App).

%% @doc Register a cli command (e.g.: "riak-admin handoff status", or "riak-admin cluster join '*'")
-spec register_command(['*' | string()], '_' | list(), list(), fun()) -> ok | {error, atom()}.
register_command(Cmd, Keys, Flags, Fun) ->
    clique_command:register(Cmd, Keys, Flags, Fun).

-spec unregister_command(['*' | string()]) -> ok | {error, atom()}.
unregister_command(Cmd) ->
    clique_command:unregister(Cmd).

%% @doc Register usage for a given command sequence. Lookups are by longest
%% match.
-spec register_usage([string()], clique_usage:usage()) -> true.
register_usage(Cmd, Usage) ->
    clique_usage:register(Cmd, Usage).

-spec unregister_usage([string()]) -> true.
unregister_usage(Cmd) ->
    clique_usage:unregister(Cmd).

%% @doc Take a list of status types and generate console output
-spec print({error, term()}, term()) -> {error, 1};
           ({clique_status:status(), integer(), string()}, [string()]) -> ok | {error, integer()};
           (clique_status:status(), [string()]) -> ok.
print({error, _} = E, Cmd) ->
    print(E, Cmd, "human"),
    {error, 1};
print({Status, ExitCode, Format}, Cmd) ->
    print(Status, Cmd, Format),
    case ExitCode of
        0 -> ok;
        _ -> {error, ExitCode}
    end;
print(Status, Cmd) ->
    print(Status, Cmd, "human"),
    ok.

-spec print(usage | err() | clique_status:status(), [string()], string()) ->
    ok | {error, integer()}.
print(usage, Cmd, _Format) ->
    clique_usage:print(Cmd);
print({error, _}=E, Cmd, Format) ->
    Alert = clique_error:format(hd(Cmd), E),
    print(Alert, Cmd, Format);
print(Status, _Cmd, Format) ->
    {Stdout, Stderr} = clique_writer:write(Status, Format),
    %% This is kind of a hack, but I'm not aware of a better way to do this.
    %% When the RPC call is executed, it replaces the group_leader with that
    %% of the calling process, so that stdout is automatically redirected to
    %% the caller. However, stderr is not. To get the correct PID for stderr,
    %% we need to do an RPC back to the calling node and get it from them.
    CallingNode = node(group_leader()),
    RemoteStderr = rpc:call(CallingNode, erlang, whereis, [standard_error]),
    io:format("~ts", [Stdout]),
    io:format(RemoteStderr, "~ts", [Stderr]).

%% @doc Run a config operation or command
-spec run([string()]) -> ok | {error, integer()}.
run(Cmd) ->
    M0 = clique_command:match(Cmd),
    M1 = clique_parser:parse(M0),
    M2 = clique_parser:extract_global_flags(M1),
    M3 = clique_parser:validate(M2),
    print(clique_command:run(M3), Cmd).

-ifdef(TEST).

basic_cmd_test() ->
    clique_manager:start_link(), %% May already be started from a different test, which is fine.
    Cmd = ["clique-test", "basic_cmd_test"],
    Callback = fun(CallbackCmd, [], []) ->
                       ?assertEqual(Cmd, CallbackCmd),
                       put(pass_basic_cmd_test, true),
                       [] %% Need to return a valid status, but don't care what's in it
               end,
    ?assertEqual(ok, register_command(Cmd, [], [], Callback)),
    ?assertEqual(ok, run(Cmd)),
    ?assertEqual(true, get(pass_basic_cmd_test)).

cmd_error_status_test() ->
    clique_manager:start_link(), %% May already be started from a different test, which is fine.
    Cmd = ["clique-test", "cmd_error_status_test"],
    Callback = fun(_, [], []) -> {exit_status, 123, []} end,
    ?assertEqual(ok, register_command(Cmd, [], [], Callback)),
    ?assertEqual({error, 123}, run(Cmd)).

-endif.
