-module(jet_port_ffi).
-export([open/2, send_input/2, close/1, cleanup_all/0]).

%% Open an external process via erlang:open_port
%% Command: string or binary
%% Opts: list of port options (e.g., [binary, {line, 1024}, stderr_to_stdout])
open(Command, Opts) ->
    CmdStr = ensure_list(Command),
    %% `separate_stderr` (pseudo-opt) keeps stderr off stdout, as ACP requires
    %% (stdout must contain only valid protocol messages).
    {SepStderr, Opts1} = case lists:member(separate_stderr, Opts) of
        true -> {true, lists:delete(separate_stderr, Opts)};
        false -> {false, Opts}
    end,
    DefaultOpts = case SepStderr of
        true -> [binary, exit_status, use_stdio];
        false -> [binary, exit_status, use_stdio, stderr_to_stdout]
    end,
    MergedOpts = merge_opts(DefaultOpts, Opts1),
    try
        Port = erlang:open_port({spawn, CmdStr}, MergedOpts),
        track_pid(Port),
        {ok, Port}
    catch
        error:Reason -> {error, Reason}
    end.

%% --- adapter-pid tracking, so an escript can kill leftover adapters before its
%% abrupt erlang:halt (which skips the connection's DOWN -> close cleanup). The
%% long-lived case (an acp-serve client) is already covered by close/1 on agent death.
track_pid(Port) ->
    case catch erlang:port_info(Port, os_pid) of
        {os_pid, P} ->
            persistent_term:put(jet_acp_pids,
                lists:usort([P | persistent_term:get(jet_acp_pids, [])]));
        _ -> ok
    end.

untrack_pid(P) ->
    persistent_term:put(jet_acp_pids,
        lists:delete(P, persistent_term:get(jet_acp_pids, []))).

%% Kill every still-tracked adapter tree. Call before an escript exits.
cleanup_all() ->
    lists:foreach(fun kill_tree/1, persistent_term:get(jet_acp_pids, [])),
    catch persistent_term:erase(jet_acp_pids),
    ok.

%% Send data to port's stdin
send_input(Port, Data) ->
    BinData = ensure_binary(Data),
    Port ! {self(), {command, BinData}},
    ok.

%% Close a port AND kill the spawned process tree. erlang:port_close only sends
%% EOF to the child's stdin; a node-based ACP adapter (claude-code-acp spawns sh
%% -> node -> node claude-agent-sdk) does not exit on that, so it leaks. We grab
%% the OS pid first and kill it plus all descendants (bottom-up).
close(Port) ->
    OsPid = case catch erlang:port_info(Port, os_pid) of
        {os_pid, P} -> P;
        _ -> undefined
    end,
    %% Kill the tree BEFORE port_close: closing the port makes the sh wrapper
    %% exit, which reparents its node child to init (PID 1) and lets it escape a
    %% parent-based tree walk. Killing first keeps the tree intact.
    case OsPid of
        undefined -> ok;
        _ -> kill_tree(OsPid), untrack_pid(OsPid)
    end,
    catch erlang:port_close(Port),
    ok.

%% Kill a pid and every descendant (children spawned by ACP adapters), so no
%% subprocess is left running after a connection closes.
kill_tree(Pid) ->
    Children = string:tokens(os:cmd("pgrep -P " ++ integer_to_list(Pid)), "\n"),
    lists:foreach(
        fun(C) ->
            case string:to_integer(string:trim(C)) of
                {Cpid, _} when is_integer(Cpid) -> kill_tree(Cpid);
                _ -> ok
            end
        end, Children),
    os:cmd("kill -TERM " ++ integer_to_list(Pid)),
    ok.

%% Merge option lists, avoiding duplicates of atom options
merge_opts(Defaults, UserOpts) ->
    %% User opts override defaults
    FilteredDefaults = lists:filter(
        fun(Opt) ->
            OptKey = opt_key(Opt),
            not lists:any(fun(UOpt) -> opt_key(UOpt) =:= OptKey end, UserOpts)
        end,
        Defaults),
    FilteredDefaults ++ UserOpts.

opt_key({K, _}) -> K;
opt_key(K) -> K.

ensure_list(V) when is_list(V) -> V;
ensure_list(V) when is_binary(V) -> binary_to_list(V).

ensure_binary(V) when is_binary(V) -> V;
ensure_binary(V) when is_list(V) -> list_to_binary(V).
