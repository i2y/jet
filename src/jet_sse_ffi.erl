-module(jet_sse_ffi).
-export([parse_events/1, parse_event/1]).

%% Parse a buffer of SSE data into a list of events.
%% SSE format: "event: type\ndata: {...}\n\n"
%% Returns: [{EventType, Data}]
parse_events(Buffer) ->
    %% Split by double newline (event boundary)
    Blocks = binary:split(Buffer, [<<"\n\n">>, <<"\r\n\r\n">>], [global, trim_all]),
    [parse_event(Block) || Block <- Blocks, Block =/= <<>>].

%% Parse a single SSE event block into {EventType, Data}
parse_event(Block) ->
    Lines = binary:split(Block, [<<"\n">>, <<"\r\n">>], [global]),
    parse_lines(Lines, <<"message">>, []).

parse_lines([], EventType, DataAcc) ->
    Data = iolist_to_binary(lists:join(<<"\n">>, lists:reverse(DataAcc))),
    {EventType, Data};
parse_lines([Line | Rest], EventType, DataAcc) ->
    case Line of
        <<"event: ", Type/binary>> ->
            parse_lines(Rest, string:trim(Type), DataAcc);
        <<"event:", Type/binary>> ->
            parse_lines(Rest, string:trim(Type), DataAcc);
        <<"data: ", Data/binary>> ->
            parse_lines(Rest, EventType, [Data | DataAcc]);
        <<"data:", Data/binary>> ->
            parse_lines(Rest, EventType, [Data | DataAcc]);
        <<"id: ", _/binary>> ->
            parse_lines(Rest, EventType, DataAcc);
        <<"id:", _/binary>> ->
            parse_lines(Rest, EventType, DataAcc);
        <<"retry: ", _/binary>> ->
            parse_lines(Rest, EventType, DataAcc);
        <<"retry:", _/binary>> ->
            parse_lines(Rest, EventType, DataAcc);
        <<":", _/binary>> ->
            %% Comment line, skip
            parse_lines(Rest, EventType, DataAcc);
        <<>> ->
            parse_lines(Rest, EventType, DataAcc);
        _ ->
            %% Unknown line, treat as data
            parse_lines(Rest, EventType, [Line | DataAcc])
    end.
