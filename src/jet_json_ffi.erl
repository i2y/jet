-module(jet_json_ffi).
-export([encode/1, decode/1]).

%%% JSON Encoder — handles Jet-specific types (atoms, tuples, charlists)

encode(Term) ->
    iolist_to_binary(encode_value(Term)).

encode_value(true) -> <<"true">>;
encode_value(false) -> <<"false">>;
encode_value(nil) -> <<"null">>;
encode_value(null) -> <<"null">>;
encode_value(undefined) -> <<"null">>;
encode_value(V) when is_integer(V) -> integer_to_binary(V);
encode_value(V) when is_float(V) -> float_to_binary(V, [{decimals, 17}, compact]);
encode_value(V) when is_binary(V) -> encode_string(V);
encode_value(V) when is_atom(V) -> encode_string(atom_to_binary(V, utf8));
encode_value(V) when is_list(V) ->
    case is_charlist(V) of
        true -> encode_string(unicode:characters_to_binary(V));
        false -> encode_array(V)
    end;
encode_value(V) when is_map(V) -> encode_object(V);
encode_value({}) -> encode_object(#{});
encode_value(V) when is_tuple(V) ->
    encode_array(tuple_to_list(V)).

encode_string(Bin) ->
    [<<"\"">>, escape_string(Bin, <<>>), <<"\"">>].

escape_string(<<>>, Acc) -> Acc;
escape_string(<<$", Rest/binary>>, Acc) -> escape_string(Rest, <<Acc/binary, $\\, $">>);
escape_string(<<$\\, Rest/binary>>, Acc) -> escape_string(Rest, <<Acc/binary, $\\, $\\>>);
escape_string(<<$\n, Rest/binary>>, Acc) -> escape_string(Rest, <<Acc/binary, $\\, $n>>);
escape_string(<<$\r, Rest/binary>>, Acc) -> escape_string(Rest, <<Acc/binary, $\\, $r>>);
escape_string(<<$\t, Rest/binary>>, Acc) -> escape_string(Rest, <<Acc/binary, $\\, $t>>);
escape_string(<<C, Rest/binary>>, Acc) when C < 16#20 ->
    Hex = list_to_binary(io_lib:format("\\u~4.16.0B", [C])),
    escape_string(Rest, <<Acc/binary, Hex/binary>>);
escape_string(<<C/utf8, Rest/binary>>, Acc) ->
    Encoded = <<C/utf8>>,
    escape_string(Rest, <<Acc/binary, Encoded/binary>>).

encode_array(List) ->
    Elements = lists:join(<<",">>, [encode_value(E) || E <- List]),
    [<<"[">>, Elements, <<"]">>].

encode_object(Map) when is_map(Map) ->
    Pairs = maps:fold(
        fun(K, V, Acc) ->
            Key = if
                is_atom(K) -> atom_to_binary(K, utf8);
                is_binary(K) -> K;
                is_list(K) -> list_to_binary(K);
                true -> iolist_to_binary(io_lib:format("~p", [K]))
            end,
            [[encode_string(Key), <<":">>, encode_value(V)] | Acc]
        end,
        [],
        Map),
    [<<"{">>, lists:join(<<",">>, Pairs), <<"}">>].

is_charlist([]) -> true;
is_charlist([H|T]) when is_integer(H), H >= 0, H =< 16#10FFFF -> is_charlist(T);
is_charlist(_) -> false.

%%% JSON Decoder — delegates to gleam_json_ffi

decode(Bin) when is_binary(Bin) ->
    gleam_json_ffi:decode(Bin);
decode(List) when is_list(List) ->
    decode(list_to_binary(List)).
