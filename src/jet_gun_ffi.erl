-module(jet_gun_ffi).
-export([connect/3, post/4, await_response/2, stream_response/3, close/1]).

%% Connect to a host via gun (HTTP/2 with TLS)
connect(Host, Port, Opts) ->
    HostStr = ensure_list(Host),
    GunOpts = maps:merge(#{
        protocols => [http2, http],
        transport => tls,
        tls_opts => ssl_opts()
    }, Opts),
    case gun:open(HostStr, Port, GunOpts) of
        {ok, ConnPid} ->
            case gun:await_up(ConnPid, 10000) of
                {ok, _Protocol} ->
                    {ok, ConnPid};
                {error, Reason} ->
                    gun:close(ConnPid),
                    {error, {connect_timeout, Reason}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% Send a POST request
post(ConnPid, Path, Headers, Body) ->
    PathStr = ensure_list(Path),
    HeadersList = [{ensure_binary(K), ensure_binary(V)} || {K, V} <- Headers],
    BodyBin = ensure_binary(Body),
    StreamRef = gun:post(ConnPid, PathStr, HeadersList, BodyBin),
    {ok, StreamRef}.

%% Await a complete response (synchronous)
await_response(ConnPid, StreamRef) ->
    case gun:await(ConnPid, StreamRef, 120000) of
        {response, fin, Status, RespHeaders} ->
            {ok, #{status => Status, headers => RespHeaders, body => <<>>}};
        {response, nofin, Status, RespHeaders} ->
            case gun:await_body(ConnPid, StreamRef, 120000) of
                {ok, Body} ->
                    {ok, #{status => Status, headers => RespHeaders, body => Body}};
                {error, Reason} ->
                    {error, {body_error, Reason}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% Stream response chunks to a callback fun
%% Callback receives: {data, Binary} | {done, Binary} | {error, Reason}
stream_response(ConnPid, StreamRef, Callback) ->
    case gun:await(ConnPid, StreamRef, 120000) of
        {response, fin, Status, _RespHeaders} ->
            Callback({done, <<>>}),
            {ok, Status};
        {response, nofin, Status, _RespHeaders} ->
            stream_body(ConnPid, StreamRef, Callback),
            {ok, Status};
        {error, Reason} ->
            Callback({error, Reason}),
            {error, Reason}
    end.

stream_body(ConnPid, StreamRef, Callback) ->
    receive
        {gun_data, ConnPid, StreamRef, nofin, Data} ->
            Callback({data, Data}),
            stream_body(ConnPid, StreamRef, Callback);
        {gun_data, ConnPid, StreamRef, fin, Data} ->
            Callback({done, Data}),
            ok;
        {gun_error, ConnPid, StreamRef, Reason} ->
            Callback({error, Reason}),
            {error, Reason}
    after 120000 ->
        Callback({error, timeout}),
        {error, timeout}
    end.

%% Close connection
close(ConnPid) ->
    gun:close(ConnPid),
    ok.

%% Internal helpers

ssl_opts() ->
    try
        CaCerts = public_key:cacerts_get(),
        [{verify, verify_peer},
         {cacerts, CaCerts},
         {depth, 3},
         {customize_hostname_check,
          [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}]
    catch
        _:_ ->
            [{verify, verify_none}]
    end.

ensure_list(V) when is_list(V) -> V;
ensure_list(V) when is_binary(V) -> binary_to_list(V);
ensure_list(V) when is_atom(V) -> atom_to_list(V).

ensure_binary(V) when is_binary(V) -> V;
ensure_binary(V) when is_list(V) -> list_to_binary(V);
ensure_binary(V) when is_atom(V) -> atom_to_binary(V, utf8).
