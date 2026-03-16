-module(jet_yaml_ffi).
-export([parse/1, parse_file/1]).

%% Parse a YAML string into an Erlang map
parse(Bin) when is_binary(Bin) ->
    parse(binary_to_list(Bin));
parse(Str) when is_list(Str) ->
    try
        application:ensure_all_started(yamerl),
        Docs = yamerl_constr:string(Str, [{detailed_constr, false}]),
        case Docs of
            [Doc] -> {ok, proplist_to_map(Doc)};
            [] -> {ok, #{}};
            Multiple -> {ok, [proplist_to_map(D) || D <- Multiple]}
        end
    catch
        _:Reason -> {error, Reason}
    end.

%% Parse a YAML file
parse_file(Path) ->
    PathStr = ensure_list(Path),
    try
        application:ensure_all_started(yamerl),
        Docs = yamerl_constr:file(PathStr, [{detailed_constr, false}]),
        case Docs of
            [Doc] -> {ok, proplist_to_map(Doc)};
            [] -> {ok, #{}};
            Multiple -> {ok, [proplist_to_map(D) || D <- Multiple]}
        end
    catch
        _:Reason -> {error, Reason}
    end.

%% Convert yamerl proplist output to Erlang maps (recursive)
proplist_to_map(List) when is_list(List) ->
    case is_proplist(List) of
        true ->
            maps:from_list([{list_to_binary_safe(K), convert_value(V)}
                           || {K, V} <- List]);
        false ->
            [convert_value(E) || E <- List]
    end;
proplist_to_map(Other) ->
    convert_value(Other).

convert_value(List) when is_list(List) ->
    case is_proplist(List) of
        true -> proplist_to_map(List);
        false ->
            case is_charlist(List) of
                true -> list_to_binary(List);
                false -> [convert_value(E) || E <- List]
            end
    end;
convert_value(null) -> nil;
convert_value(V) -> V.

is_proplist([{_, _} | T]) -> is_proplist(T);
is_proplist([]) -> true;
is_proplist(_) -> false.

is_charlist([]) -> true;
is_charlist([H|T]) when is_integer(H), H >= 0, H =< 16#10FFFF -> is_charlist(T);
is_charlist(_) -> false.

list_to_binary_safe(V) when is_list(V) -> list_to_binary(V);
list_to_binary_safe(V) when is_binary(V) -> V;
list_to_binary_safe(V) when is_atom(V) -> atom_to_binary(V, utf8);
list_to_binary_safe(V) -> iolist_to_binary(io_lib:format("~p", [V])).

ensure_list(V) when is_list(V) -> V;
ensure_list(V) when is_binary(V) -> binary_to_list(V).
