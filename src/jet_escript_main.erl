-module(jet_escript_main).
-export([main/1]).

main(_Args) ->
    %% Store escript location so jet_cli_ffi can find stdlib beams
    ScriptName = escript:script_name(),
    JetDir = filename:dirname(filename:absname(ScriptName)),
    persistent_term:put(jet_home_dir, JetDir),
    'jet@@main':run(jet).
