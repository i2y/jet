#!/usr/bin/env escript
%% Script to build jet escript from the compiled BEAM files
-include_lib("kernel/include/file.hrl").

main(_) ->
    %% Collect all .beam and .app files from the shipment
    BeamDirs = filelib:wildcard("build/erlang-shipment/*/ebin"),
    Files = lists:flatmap(
        fun(Dir) ->
            AllFiles = filelib:wildcard(Dir ++ "/*.beam") ++
                       filelib:wildcard(Dir ++ "/*.app"),
            lists:map(
                fun(File) ->
                    Name = filename:basename(File),
                    {ok, Bin} = file:read_file(File),
                    {Name, Bin}
                end,
                AllFiles)
        end,
        BeamDirs),

    %% Create escript
    EscriptOpts = [
        {shebang, "/usr/bin/env escript"},
        {emu_args, "-escript main jet_escript_main"},
        {archive, Files, []}
    ],
    {ok, Escript} = escript:create(binary, EscriptOpts),
    ok = file:write_file("jet", Escript),

    %% Make executable
    os:cmd("chmod +x jet"),

    io:format("Built jet escript successfully!~n").
