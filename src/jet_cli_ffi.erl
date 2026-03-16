-module(jet_cli_ffi).
-export([write_beam/2, call_module_func/2, add_code_path/1, setup_code_paths/0,
         get_stdlib_beam_dir/0, do_build_escript/3, do_build_release/3]).

write_beam(Path, Binary) when is_binary(Path) ->
    case file:write_file(binary_to_list(Path), Binary) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.

%% Find the jet escript/binary location and add its stdlib path.
%% Called once at startup before any compilation or execution.
setup_code_paths() ->
    JetDir = find_jet_dir(),
    StdlibDir = filename:join(JetDir, "src"),
    code:add_pathz(StdlibDir),
    %% Also add subdirectories of src/ for Symphony etc.
    case file:list_dir(StdlibDir) of
        {ok, Entries} ->
            lists:foreach(fun(Entry) ->
                SubDir = filename:join(StdlibDir, Entry),
                case filelib:is_dir(SubDir) of
                    true -> code:add_pathz(SubDir);
                    false -> ok
                end
            end, Entries);
        _ -> ok
    end,
    nil.

find_jet_dir() ->
    %% jet_escript_main stores this at startup
    case persistent_term:get(jet_home_dir, undefined) of
        undefined ->
            %% Running via gleam test / gleam run — use cwd
            {ok, Cwd} = file:get_cwd(),
            Cwd;
        Dir ->
            Dir
    end.

call_module_func(Module, Func) when is_binary(Module), is_binary(Func) ->
    ModAtom = binary_to_atom(Module, utf8),
    FuncAtom = resolve_func_name(Func),
    apply(ModAtom, FuncAtom, []),
    nil.

resolve_func_name(Func) ->
    case binary:split(Func, <<".">>) of
        [ClassName, MethodName] ->
            binary_to_atom(<<"_", ClassName/binary, "_class_method_", MethodName/binary>>, utf8);
        _ ->
            binary_to_atom(Func, utf8)
    end.

add_code_path(Dir) when is_binary(Dir) ->
    code:add_pathz(binary_to_list(Dir)),
    nil.

%% Return the stdlib beam directory path
get_stdlib_beam_dir() ->
    JetDir = find_jet_dir(),
    list_to_binary(filename:join(JetDir, "src")).

%% --- Escript builder ---

do_build_escript(AppModule, BeamDirs, OutputPath) ->
    try
        %% Collect all .beam files from the specified directories
        Files = lists:flatmap(fun(Dir) -> collect_beam_files(Dir) end, BeamDirs),

        %% Generate the entry point module
        EntryBeam = generate_escript_entry(AppModule),
        AllFiles = [EntryBeam | Files],

        %% Deduplicate by filename (first occurrence wins)
        UniqueFiles = deduplicate_files(AllFiles),

        %% Build escript
        EscriptOpts = [
            {shebang, "/usr/bin/env escript"},
            {emu_args, "-escript main jet_user_app_main"},
            {archive, UniqueFiles, []}
        ],
        {ok, Escript} = escript:create(binary, EscriptOpts),
        OutPath = binary_to_list(OutputPath),
        ok = file:write_file(OutPath, Escript),
        os:cmd("chmod +x " ++ OutPath),
        {ok, nil}
    catch
        _:Reason ->
            {error, list_to_binary(lists:flatten(
                io_lib:format("~p", [Reason])))}
    end.

%% Collect .beam files from a directory (non-recursive)
collect_beam_files(Dir) ->
    DirStr = binary_to_list(Dir),
    Pattern = DirStr ++ "/*.beam",
    lists:map(
        fun(File) ->
            Name = filename:basename(File),
            {ok, Bin} = file:read_file(File),
            {Name, Bin}
        end,
        filelib:wildcard(Pattern)).

%% Generate an entry point module for the user's escript
%% Calls AppModule:main() — Jet module-level `def self.main()` compiles to main/0
generate_escript_entry(AppModule) ->
    ModAtom = binary_to_atom(AppModule, utf8),
    Forms = [
        {attribute, 1, module, jet_user_app_main},
        {attribute, 2, export, [{main, 1}]},
        {function, 3, main, 1,
         [{clause, 3, [{var, 3, '_Args'}], [],
           [{call, 4,
             {remote, 4, {atom, 4, ModAtom}, {atom, 4, main}},
             []}]}]}
    ],
    {ok, _, Binary} = compile:forms(Forms),
    {"jet_user_app_main.beam", Binary}.

%% Deduplicate files by name (keep first occurrence)
deduplicate_files(Files) ->
    deduplicate_files(Files, #{}, []).

deduplicate_files([], _Seen, Acc) ->
    lists:reverse(Acc);
deduplicate_files([{Name, _Bin} = F | Rest], Seen, Acc) ->
    case maps:is_key(Name, Seen) of
        true -> deduplicate_files(Rest, Seen, Acc);
        false -> deduplicate_files(Rest, Seen#{Name => true}, [F | Acc])
    end.

%% --- Release builder ---

do_build_release(AppModule, BeamDirs, OutputDir) ->
    try
        OutDir = binary_to_list(OutputDir),
        BinDir = filename:join(OutDir, "bin"),
        EbinDir = filename:join(OutDir, "ebin"),
        filelib:ensure_dir(filename:join(BinDir, "dummy")),
        filelib:ensure_dir(filename:join(EbinDir, "dummy")),

        %% Collect and copy all .beam files to ebin/
        Files = lists:flatmap(fun(Dir) -> collect_beam_files(Dir) end, BeamDirs),
        UniqueFiles = deduplicate_files(Files),
        lists:foreach(fun({Name, Bin}) ->
            file:write_file(filename:join(EbinDir, Name), Bin)
        end, UniqueFiles),

        %% Generate the entry module for the release
        {EntryName, EntryBin} = generate_release_entry(AppModule),
        file:write_file(filename:join(EbinDir, EntryName), EntryBin),

        %% Generate .app file
        AppName = string:lowercase(binary_to_list(AppModule)),
        Modules = list_beam_modules(EbinDir),
        AppSpec = {application, list_to_atom(AppName), [
            {vsn, "1.0.0"},
            {modules, Modules},
            {registered, []},
            {applications, [kernel, stdlib]}
        ]},
        AppFile = filename:join(EbinDir, AppName ++ ".app"),
        file:write_file(AppFile, io_lib:format("~p.~n", [AppSpec])),

        %% Generate launcher shell script
        %% Use -eval to add code path AFTER OTP boots, avoiding Kernel.beam
        %% shadowing OTP's kernel module on case-insensitive filesystems
        LauncherPath = filename:join(BinDir, AppName),
        ModAtom = binary_to_list(AppModule),
        LauncherContent = lists:flatten(io_lib:format(
            "#!/bin/sh\n"
            "SCRIPT_DIR=$(cd \"$(dirname \"$0\")\" && pwd)\n"
            "ROOT_DIR=$(cd \"$SCRIPT_DIR/..\" && pwd)\n"
            "exec erl -noshell "
            "-eval \"code:add_pathz(\\\"$ROOT_DIR/ebin\\\"), '~s':main(), init:stop()\""
            " -- \"$@\"\n",
            [ModAtom])),
        file:write_file(LauncherPath, LauncherContent),
        os:cmd("chmod +x " ++ LauncherPath),

        {ok, nil}
    catch
        _:Reason ->
            {error, list_to_binary(lists:flatten(
                io_lib:format("~p", [Reason])))}
    end.

%% Generate release entry module
%% Calls AppModule:main() — Jet module-level `def self.main()` compiles to main/0
generate_release_entry(AppModule) ->
    ModAtom = binary_to_atom(AppModule, utf8),
    Forms = [
        {attribute, 1, module, jet_release_main},
        {attribute, 2, export, [{main, 0}]},
        {function, 3, main, 0,
         [{clause, 3, [], [],
           [{call, 4,
             {remote, 4, {atom, 4, ModAtom}, {atom, 4, main}},
             []}]}]}
    ],
    {ok, _, Binary} = compile:forms(Forms),
    {"jet_release_main.beam", Binary}.

%% List all module atoms from .beam files in a directory
list_beam_modules(EbinDir) ->
    Beams = filelib:wildcard(filename:join(EbinDir, "*.beam")),
    lists:map(fun(F) ->
        list_to_atom(filename:rootname(filename:basename(F)))
    end, Beams).

