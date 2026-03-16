-module(jet_http_ffi).
-export([post/3, post_stream/4, ensure_started/0]).

%% Ensure gun + SSL applications are started
ensure_started() ->
    application:ensure_all_started(gun),
    ok.

%% Synchronous POST — compatible with existing Llm.jet API
post(Url, Headers, Body) ->
    {Host, Port, Path} = parse_url(Url),
    case jet_gun_ffi:connect(Host, Port, #{}) of
        {ok, ConnPid} ->
            try
                {ok, StreamRef} = jet_gun_ffi:post(ConnPid, Path, Headers, Body),
                case jet_gun_ffi:await_response(ConnPid, StreamRef) of
                    {ok, #{status := StatusCode, body := RespBody}} ->
                        {ok, #{status => StatusCode, body => RespBody}};
                    {error, Reason} ->
                        {error, Reason}
                end
            after
                jet_gun_ffi:close(ConnPid)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% Streaming POST — for SSE (Server-Sent Events)
%% Callback receives: {data, Binary} | {done, Binary} | {error, Reason}
post_stream(Url, Headers, Body, Callback) ->
    {Host, Port, Path} = parse_url(Url),
    case jet_gun_ffi:connect(Host, Port, #{}) of
        {ok, ConnPid} ->
            {ok, StreamRef} = jet_gun_ffi:post(ConnPid, Path, Headers, Body),
            Result = jet_gun_ffi:stream_response(ConnPid, StreamRef, Callback),
            jet_gun_ffi:close(ConnPid),
            Result;
        {error, Reason} ->
            Callback({error, Reason}),
            {error, Reason}
    end.

%% Parse URL into {Host, Port, Path}
parse_url(Url) ->
    UrlStr = ensure_list(Url),
    case uri_string:parse(UrlStr) of
        #{scheme := Scheme, host := Host, path := Path} = Parsed ->
            Port = maps:get(port, Parsed, default_port(Scheme)),
            {Host, Port, Path};
        _ ->
            %% Fallback: simple parse
            parse_url_simple(UrlStr)
    end.

default_port("https") -> 443;
default_port(<<"https">>) -> 443;
default_port("http") -> 80;
default_port(<<"http">>) -> 80;
default_port(_) -> 443.

parse_url_simple(Url) ->
    %% Strip scheme
    {_Scheme, Rest} = case Url of
        "https://" ++ R -> {https, R};
        "http://" ++ R -> {http, R};
        R -> {https, R}
    end,
    %% Split host and path
    case string:split(Rest, "/") of
        [HostPort, Path0] ->
            Path = "/" ++ Path0,
            {Host, Port} = parse_host_port(HostPort),
            {Host, Port, Path};
        [HostPort] ->
            {Host, Port} = parse_host_port(HostPort),
            {Host, Port, "/"}
    end.

parse_host_port(HostPort) ->
    case string:split(HostPort, ":") of
        [Host, PortStr] -> {Host, list_to_integer(PortStr)};
        [Host] -> {Host, 443}
    end.

ensure_list(V) when is_list(V) -> V;
ensure_list(V) when is_binary(V) -> binary_to_list(V);
ensure_list(V) when is_atom(V) -> atom_to_list(V).
