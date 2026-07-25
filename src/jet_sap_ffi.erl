-module(jet_sap_ffi).

%%% Schema-Aligned Parsing, stage 1 of 2: the LENIENT PARSER.
%%%
%%% Postel's law applied to model output -- be conservative in what you send,
%%% liberal in what you accept. A model asked for "only JSON" will still wrap it
%%% in markdown, think out loud first, drop a comma, or quote with '. Rather than
%%% making the model obey a strict format, this parser repairs what arrived.
%%%
%%% It deliberately OVER-generates: every plausible reading of the text comes back
%%% as a candidate, each tagged with the repairs that were needed to get it. Stage
%%% 2 (jet_sap.jet) coerces each candidate to the declared schema, scores the
%%% repairs, and keeps the cheapest -- so the SCHEMA decides, not this module.
%%%
%%% Repairs handled here:
%%%   - <think>...</think> / <thinking>...</thinking>       reasoning models
%%%   - ```json ... ``` and bare ``` ... ``` fences          markdown wrapping
%%%   - prose before and/or after the value                  yapping
%%%   - trailing commas, missing commas, stray commas
%%%   - single-quoted strings, unquoted object keys
%%%   - // # line and /* block */ comments
%%%   - Python literals True / False / None, NaN, Infinity
%%%   - raw newlines/tabs inside strings
%%%   - UNESCAPED quotes inside strings ("he said "hi" there")
%%%   - fractions where a float belongs (1/3 -> 0.333...)
%%%   - truncated objects/arrays -- what parsed so far is kept, flagged incomplete
%%%
%%% Ported from the design of BoundaryML's `jsonish` crate (Apache-2.0); the
%%% repair->cost weights live in jet_sap.jet, mirroring its score.rs.

-export([parse/1, parse_all/1, scalars/1]).

%% How many `{`/`[` offsets to try when the value is buried in prose. Sub-binaries
%% are references (no copy), so each costs one parse attempt; the cap just bounds
%% pathological input. Taken from BOTH ends so a value that follows a long
%% preamble is still reached.
-define(FIRST_STARTS, 16).
-define(LAST_STARTS, 8).

-define(FLAGS, '$jet_sap_flags').

%% ---------------------------------------------------------------- public ----

%% The single best-guess value, ignoring flags. `error` when there is no JSON.
parse(Input) ->
    case parse_all(Input) of
        [] -> error;
        [{V, _Flags} | _] -> {ok, V}
    end.

%% Every plausible value as {Value, Flags}, best-first and de-duplicated by value:
%%   fenced blocks -> the whole text -> each `{`/`[` offset.
%% Flags are the repairs this candidate needed: from_markdown | embedded |
%% incomplete | inner_quote | fraction.
parse_all(L) when is_list(L) ->
    parse_all(unicode:characters_to_binary(L));
parse_all(Bin) when is_binary(Bin) ->
    %% model output is untrusted bytes -- a stream cut mid-codepoint yields
    %% invalid UTF-8, and no reply is worth crashing a turn over
    try dedup(collect(candidates(strip_think(Bin))), [])
    catch _:_ -> [] end;
parse_all(_) ->
    [].

collect([]) -> [];
collect([{C, Flags0} | Rest]) ->
    put(?FLAGS, []),
    Parsed = try value(C) catch _:_ -> error end,
    Repairs = case get(?FLAGS) of undefined -> []; L -> L end,
    erase(?FLAGS),
    case Parsed of
        {ok, V, _} -> [{V, lists:usort(Flags0 ++ Repairs)} | collect(Rest)];
        _ -> collect(Rest)
    end.

%% de-dupe by VALUE, keeping the first (best-flagged) occurrence
dedup([], _Seen) -> [];
dedup([{V, F} | R], Seen) ->
    case lists:member(V, Seen) of
        true -> dedup(R, Seen);
        false -> [{V, F} | dedup(R, [V | Seen])]
    end.

flag(F) ->
    case get(?FLAGS) of
        undefined -> ok;                 %% called outside a collect/1 pass
        L -> put(?FLAGS, [F | L])
    end.

%% Numbers and boolean words appearing ANYWHERE in the text, in order. Last-resort
%% candidates for a scalar schema, so `-> Int` still finds the 42 in "The answer
%% is 42." They are priced as substring_match by the caller -- a clean value
%% always wins.
scalars(L) when is_list(L) -> scalars(unicode:characters_to_binary(L));
scalars(Bin) when is_binary(Bin) -> uniq(scan(Bin, 0, []), []);
scalars(_) -> [].

uniq([], _Seen) -> [];
uniq([V | R], Seen) ->
    case lists:member(V, Seen) of
        true -> uniq(R, Seen);
        false -> [V | uniq(R, [V | Seen])]
    end.

scan(Bin, Pos, Acc) when Pos >= byte_size(Bin) ->
    lists:reverse(Acc);
scan(Bin, Pos, Acc) ->
    case word_start(Bin, Pos) of
        false -> scan(Bin, Pos + 1, Acc);
        true ->
            Rest = binary:part(Bin, Pos, byte_size(Bin) - Pos),
            case scalar_at(Rest) of
                {ok, V, Used} -> scan(Bin, Pos + Used, [V | Acc]);
                error -> scan(Bin, Pos + 1, Acc)
            end
    end.

%% only start a token at a word boundary, so "v2" does not yield 2
word_start(_Bin, 0) -> true;
word_start(Bin, Pos) ->
    case binary:at(Bin, Pos - 1) of
        C when (C >= $a andalso C =< $z);
               (C >= $A andalso C =< $Z);
               (C >= $0 andalso C =< $9);
               C =:= $_; C =:= $. -> false;
        _ -> true
    end.

scalar_at(Rest) ->
    case bool_word(alpha_run(Rest, <<>>)) of
        {ok, B, Used} -> {ok, B, Used};
        error ->
            case raw_number(Rest) of
                {ok, N, After} -> {ok, N, byte_size(Rest) - byte_size(After)};
                error -> error
            end
    end.

alpha_run(<<C, R/binary>>, Acc)
  when (C >= $a andalso C =< $z); (C >= $A andalso C =< $Z) ->
    alpha_run(R, <<Acc/binary, C>>);
alpha_run(_, Acc) -> Acc.

bool_word(W) ->
    case string:lowercase(W) of
        <<"true">> -> {ok, true, byte_size(W)};
        <<"yes">> -> {ok, true, byte_size(W)};
        <<"false">> -> {ok, false, byte_size(W)};
        <<"no">> -> {ok, false, byte_size(W)};
        _ -> error
    end.

%% ------------------------------------------------------------ extraction ----

candidates(Bin) ->
    Trimmed = trim(Bin),
    [{B, [from_markdown]} || B <- fenced(Trimmed)]
        ++ [{Trimmed, []}]
        ++ [{B, [embedded]} || B <- starts(Trimmed)].

%% Contents of ``` fenced blocks, in order, with a leading language tag dropped.
%% Splitting on ``` alternates outside/inside/outside/...; odd cells are bodies.
fenced(Bin) ->
    case binary:split(Bin, <<"```">>, [global]) of
        [_] -> [];
        Parts -> inside_cells(Parts, 0)
    end.

inside_cells([], _N) -> [];
inside_cells([_ | Rest], N) when N rem 2 =:= 0 -> inside_cells(Rest, N + 1);
inside_cells([P | Rest], N) -> [strip_lang(P) | inside_cells(Rest, N + 1)].

%% "json\n{...}" -> "{...}"  (any bare alphanumeric tag on the opening line)
strip_lang(Bin) ->
    case binary:split(Bin, <<"\n">>) of
        [Head, Tail] ->
            case is_lang_tag(trim(Head)) of
                true -> trim(Tail);
                false -> trim(Bin)
            end;
        _ -> trim(Bin)
    end.

is_lang_tag(<<>>) -> true;
is_lang_tag(Bin) -> is_lang_tag_chars(Bin).

is_lang_tag_chars(<<>>) -> true;
is_lang_tag_chars(<<C, R/binary>>)
  when (C >= $a andalso C =< $z);
       (C >= $A andalso C =< $Z);
       (C >= $0 andalso C =< $9);
       C =:= $-; C =:= $_ ->
    is_lang_tag_chars(R);
is_lang_tag_chars(_) -> false.

%% Suffixes beginning at each `{` or `[`, capped from both ends.
starts(Bin) ->
    [binary:part(Bin, P, byte_size(Bin) - P) || P <- cap(start_offsets(Bin, 0, []))].

start_offsets(Bin, Pos, Acc) when Pos >= byte_size(Bin) ->
    lists:reverse(Acc);
start_offsets(Bin, Pos, Acc) ->
    case binary:at(Bin, Pos) of
        C when C =:= ${; C =:= $[ -> start_offsets(Bin, Pos + 1, [Pos | Acc]);
        _ -> start_offsets(Bin, Pos + 1, Acc)
    end.

cap(L) ->
    case length(L) > ?FIRST_STARTS + ?LAST_STARTS of
        false -> L;
        true ->
            lists:sublist(L, ?FIRST_STARTS) ++ lists:nthtail(length(L) - ?LAST_STARTS, L)
    end.

%% Drop closed reasoning blocks. An UNCLOSED <think> is left alone: the model was
%% cut off mid-thought and the tail is all we have.
strip_think(Bin) ->
    strip_tag(strip_tag(Bin, <<"<think>">>, <<"</think>">>),
              <<"<thinking>">>, <<"</thinking>">>).

strip_tag(Bin, Open, Close) ->
    case binary:split(Bin, Open) of
        [Before, Rest] ->
            case binary:split(Rest, Close) of
                [_Thought, After] ->
                    strip_tag(<<Before/binary, After/binary>>, Open, Close);
                _ -> Bin
            end;
        _ -> Bin
    end.

%% string:trim/3 raises on invalid UTF-8; fall back to a byte-level trim so one
%% bad byte does not cost the whole reply.
trim(Bin) ->
    try string:trim(Bin, both, " \t\n\r\f\v\x{feff}")
    catch _:_ -> byte_trim_r(byte_trim_l(Bin)) end.

byte_trim_l(<<C, R/binary>>) when C =:= $\s; C =:= $\t; C =:= $\n;
                                  C =:= $\r; C =:= $\f; C =:= $\v ->
    byte_trim_l(R);
byte_trim_l(B) -> B.

byte_trim_r(<<>>) -> <<>>;
byte_trim_r(B) ->
    S = byte_size(B) - 1,
    case binary:at(B, S) of
        C when C =:= $\s; C =:= $\t; C =:= $\n;
               C =:= $\r; C =:= $\f; C =:= $\v ->
            byte_trim_r(binary:part(B, 0, S));
        _ -> B
    end.

%% ------------------------------------------------------- lenient decoding ----

value(B0) ->
    case ws(B0) of
        <<"{", R/binary>> -> object(R, #{});
        <<"[", R/binary>> -> array(R, []);
        <<$", R/binary>> -> str(R, $", <<>>);
        <<$', R/binary>> -> str(R, $', <<>>);
        <<"true", R/binary>> -> {ok, true, R};
        <<"false", R/binary>> -> {ok, false, R};
        <<"null", R/binary>> -> {ok, null, R};
        <<"True", R/binary>> -> {ok, true, R};
        <<"False", R/binary>> -> {ok, false, R};
        <<"None", R/binary>> -> {ok, null, R};
        <<"NaN", R/binary>> -> {ok, null, R};
        <<"Infinity", R/binary>> -> {ok, null, R};
        <<"-Infinity", R/binary>> -> {ok, null, R};
        B -> number(B)
    end.

%% whitespace + comments
ws(<<C, R/binary>>) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r; C =:= $\f ->
    ws(R);
ws(<<"//", R/binary>>) -> ws(skip_line(R));
ws(<<"#", R/binary>>) -> ws(skip_line(R));
ws(<<"/*", R/binary>>) -> ws(skip_block(R));
ws(B) -> B.

skip_line(<<>>) -> <<>>;
skip_line(<<$\n, R/binary>>) -> R;
skip_line(<<_, R/binary>>) -> skip_line(R).

skip_block(<<>>) -> <<>>;
skip_block(<<"*/", R/binary>>) -> R;
skip_block(<<_, R/binary>>) -> skip_block(R).

%% -- objects --

object(B0, Acc) ->
    case ws(B0) of
        <<>> -> flag(incomplete), {ok, Acc, <<>>};
        <<"}", R/binary>> -> {ok, Acc, R};
        <<",", R/binary>> -> object(R, Acc);          % stray/leading comma
        B -> member(B, Acc)
    end.

member(B, Acc) ->
    case key(B) of
        {ok, K, R1} ->
            case ws(R1) of
                <<":", R2/binary>> -> member_value(K, R2, Acc);
                _ -> error                            % a key with no colon: not an object
            end;
        error -> error
    end.

member_value(K, R2, Acc) ->
    case value(R2) of
        {ok, V, R3} ->
            Acc1 = maps:put(K, V, Acc),
            case ws(R3) of
                <<",", R4/binary>> -> object(R4, Acc1);
                <<"}", R4/binary>> -> {ok, Acc1, R4};
                <<>> -> flag(incomplete), {ok, Acc1, <<>>};
                R4 -> object(R4, Acc1)                % missing comma -- keep going
            end;
        error ->
            %% cut off right after `"key":` -- keep the members we already have
            case ws(R2) of
                <<>> -> flag(incomplete), {ok, Acc, <<>>};
                _ -> error
            end
    end.

key(B) ->
    case ws(B) of
        <<$", R/binary>> -> str(R, $", <<>>);
        <<$', R/binary>> -> str(R, $', <<>>);
        R -> bare_key(R, <<>>)
    end.

bare_key(<<C, R/binary>>, Acc)
  when (C >= $a andalso C =< $z);
       (C >= $A andalso C =< $Z);
       (C >= $0 andalso C =< $9);
       C =:= $_; C =:= $-; C =:= $. ->
    bare_key(R, <<Acc/binary, C>>);
bare_key(_, <<>>) -> error;
bare_key(R, Acc) -> {ok, Acc, R}.

%% -- arrays --

array(B0, Acc) ->
    case ws(B0) of
        <<>> -> flag(incomplete), {ok, lists:reverse(Acc), <<>>};
        <<"]", R/binary>> -> {ok, lists:reverse(Acc), R};
        <<",", R/binary>> -> array(R, Acc);           % stray/leading comma
        B -> element_of(B, Acc)
    end.

element_of(B, Acc) ->
    case value(B) of
        {ok, V, R1} ->
            case ws(R1) of
                <<",", R2/binary>> -> array(R2, [V | Acc]);
                <<"]", R2/binary>> -> {ok, lists:reverse([V | Acc]), R2};
                <<>> -> flag(incomplete), {ok, lists:reverse([V | Acc]), <<>>};
                R2 -> array(R2, [V | Acc])            % missing comma
            end;
        error -> error
    end.

%% -- strings --
%%
%% `Q` is the closing quote, so single-quoted strings work identically. Raw
%% newlines/tabs are kept verbatim rather than failing.
%%
%% A quote only CLOSES the string when what follows looks structural (`,}]:` , a
%% new quote, or end of input). Otherwise it was an unescaped quote inside the
%% text -- `"he said "hi" there"` -- and is kept as a literal character. That
%% still leaves `{"a":"x" "b":"y"}` (missing comma) parsing correctly, because a
%% following quote counts as structural.

str(<<>>, _Q, Acc) -> flag(incomplete), {ok, Acc, <<>>};
str(<<C, R/binary>>, Q, Acc) when C =:= Q ->
    case closes(R) of
        true -> {ok, Acc, R};
        false -> flag(inner_quote), str(R, Q, <<Acc/binary, C>>)
    end;
str(<<$\\, E, R/binary>>, Q, Acc) -> escape(E, R, Q, Acc);
str(<<C/utf8, R/binary>>, Q, Acc) -> str(R, Q, <<Acc/binary, C/utf8>>);
str(<<C, R/binary>>, Q, Acc) -> str(R, Q, <<Acc/binary, C>>).

closes(R) ->
    case ws(R) of
        <<>> -> true;
        <<C, _/binary>> when C =:= $,; C =:= $}; C =:= $]; C =:= $:;
                             C =:= ${; C =:= $[; C =:= $"; C =:= $' -> true;
        _ -> false
    end.

escape($n, R, Q, Acc) -> str(R, Q, <<Acc/binary, $\n>>);
escape($t, R, Q, Acc) -> str(R, Q, <<Acc/binary, $\t>>);
escape($r, R, Q, Acc) -> str(R, Q, <<Acc/binary, $\r>>);
escape($b, R, Q, Acc) -> str(R, Q, <<Acc/binary, $\b>>);
escape($f, R, Q, Acc) -> str(R, Q, <<Acc/binary, $\f>>);
escape($u, R, Q, Acc) -> unicode_escape(R, Q, Acc);
escape(C, R, Q, Acc) -> str(R, Q, <<Acc/binary, C>>).   % \" \\ \/ \' and anything else

unicode_escape(<<H:4/binary, R/binary>>, Q, Acc) ->
    case hex(H) of
        CP when is_integer(CP), CP >= 16#D800, CP =< 16#DBFF ->
            surrogate(CP, R, Q, Acc);
        CP when is_integer(CP) ->
            str(R, Q, <<Acc/binary, CP/utf8>>);
        _ ->
            str(R, Q, <<Acc/binary, "\\u", H/binary>>)
    end;
unicode_escape(R, Q, Acc) ->
    str(R, Q, <<Acc/binary, "\\u">>).

hex(Bin) -> try binary_to_integer(Bin, 16) catch _:_ -> error end.

surrogate(Hi, <<"\\u", L:4/binary, R/binary>>, Q, Acc) ->
    case hex(L) of
        Lo when is_integer(Lo), Lo >= 16#DC00, Lo =< 16#DFFF ->
            CP = 16#10000 + (Hi - 16#D800) * 16#400 + (Lo - 16#DC00),
            str(R, Q, <<Acc/binary, CP/utf8>>);
        _ ->
            str(R, Q, <<Acc/binary, 16#FFFD/utf8>>)
    end;
surrogate(_Hi, R, Q, Acc) ->
    str(R, Q, <<Acc/binary, 16#FFFD/utf8>>).

%% -- numbers --

number(B) ->
    case raw_number(B) of
        error -> error;
        {ok, N, R} -> maybe_fraction(N, R)
    end.

%% a float written as a fraction: 1/3 -> 0.3333...
maybe_fraction(N, R0) when is_number(N) ->
    case ws(R0) of
        <<"/", R1/binary>> ->
            case raw_number(R1) of
                {ok, D, R2} when is_number(D), D =/= 0, D =/= +0.0 ->
                    flag(fraction),
                    {ok, N / D, R2};
                _ -> {ok, N, R0}
            end;
        _ -> {ok, N, R0}
    end.

raw_number(B) ->
    {Sign, B1} = sign(B),
    case digits(B1, <<>>) of
        {<<>>, _} -> error;
        {Int, B2} ->
            {Frac, B3} = frac(B2),
            {Exp, B4} = expo(B3),
            Lex = <<Sign/binary, Int/binary, Frac/binary, Exp/binary>>,
            case to_number(Lex, Frac, Exp) of
                error -> error;
                N -> {ok, N, B4}
            end
    end.

sign(<<"-", R/binary>>) -> {<<"-">>, R};
sign(<<"+", R/binary>>) -> {<<>>, R};
sign(B) -> {<<>>, B}.

digits(<<C, R/binary>>, Acc) when C >= $0, C =< $9 -> digits(R, <<Acc/binary, C>>);
digits(<<$_, R/binary>>, Acc) when Acc =/= <<>> -> digits(R, Acc);   % 1_000
digits(B, Acc) -> {Acc, B}.
%% NB: "1,000" is deliberately NOT accepted -- a comma after a digit is a member
%% separator far more often than a thousands separator ([1,2] would decode as 12).

frac(<<".", R/binary>>) ->
    case digits(R, <<>>) of
        {<<>>, _} -> {<<>>, <<".", R/binary>>};
        {D, R1} -> {<<".", D/binary>>, R1}
    end;
frac(B) -> {<<>>, B}.

expo(<<E, R/binary>>) when E =:= $e; E =:= $E ->
    {S, R1} = exp_sign(R),
    case digits(R1, <<>>) of
        {<<>>, _} -> {<<>>, <<E, R/binary>>};
        {D, R2} -> {<<"e", S/binary, D/binary>>, R2}
    end;
expo(B) -> {<<>>, B}.

exp_sign(<<"-", R/binary>>) -> {<<"-">>, R};
exp_sign(<<"+", R/binary>>) -> {<<"+">>, R};
exp_sign(B) -> {<<>>, B}.

to_number(Lex, <<>>, <<>>) ->
    try binary_to_integer(Lex) catch _:_ -> error end;
to_number(Lex, Frac, Exp) ->
    %% binary_to_float/1 requires a decimal point: 1e3 -> 1.0e3
    Norm = case Frac of
        <<>> -> insert_point(Lex, Exp);
        _ -> Lex
    end,
    try binary_to_float(Norm) catch _:_ -> error end.

insert_point(Lex, Exp) ->
    Head = binary:part(Lex, 0, byte_size(Lex) - byte_size(Exp)),
    <<Head/binary, ".0", Exp/binary>>.
