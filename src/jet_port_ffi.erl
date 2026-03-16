-module(jet_port_ffi).
-export([open/2, send_input/2, close/1]).

%% Open an external process via erlang:open_port
%% Command: string or binary
%% Opts: list of port options (e.g., [binary, {line, 1024}, stderr_to_stdout])
open(Command, Opts) ->
    CmdStr = ensure_list(Command),
    DefaultOpts = [binary, exit_status, use_stdio, stderr_to_stdout],
    MergedOpts = merge_opts(DefaultOpts, Opts),
    try
        Port = erlang:open_port({spawn, CmdStr}, MergedOpts),
        {ok, Port}
    catch
        error:Reason -> {error, Reason}
    end.

%% Send data to port's stdin
send_input(Port, Data) ->
    BinData = ensure_binary(Data),
    Port ! {self(), {command, BinData}},
    ok.

%% Close a port
close(Port) ->
    try
        erlang:port_close(Port),
        ok
    catch
        error:badarg -> ok  %% Already closed
    end.

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
