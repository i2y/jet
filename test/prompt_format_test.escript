#!/usr/bin/env escript
%%% Runtime test for agent prompt formatting:
%%%   - jet_acp:args_to_text/1     (single = clean, multi = positional labels, empty = "")
%%%   - jet_acp:build_prompt/3     (multi-arg labeled by declared param NAME; single clean; fallback)
%%%   - the parser emits per-method :params (declared arg names) into the agent config
%%%
%%% Modules are loaded by BINARY (not -pa src) on purpose: on a case-insensitive macOS FS,
%%% `-pa src` makes src/Kernel.beam shadow OTP's `kernel` and the VM fails to boot.
%%%
%%% Run from the repo root:   escript test/prompt_format_test.escript
main(_) ->
    _ = os:cmd("./jet src/jet_acp.jet"),
    load_beam("src/jet_acp.beam", jet_acp),

    Cfg = #{role => [], params => #{analyze => [<<"code">>, <<"lang">>]}},
    Runtime = [
      {"single arg stays clean",        jet_acp:args_to_text([<<"hi there">>]),                    <<"hi there">>},
      {"empty args -> empty string",    jet_acp:args_to_text([]),                                  <<>>},
      {"multi args -> positional",      jet_acp:args_to_text([<<"a">>, <<"b">>]),                  <<"Argument 1:\na\n\nArgument 2:\nb">>},
      {"build_prompt named labels",     jet_acp:build_prompt(Cfg, analyze, [<<"x=1">>, <<"py">>]), <<"code:\nx=1\n\nlang:\npy">>},
      {"build_prompt single stays clean", jet_acp:build_prompt(Cfg, analyze, [<<"just text">>]),   <<"just text">>},
      {"build_prompt no names -> positional", jet_acp:build_prompt(#{}, m, [<<"a">>, <<"b">>]),    <<"Argument 1:\na\n\nArgument 2:\nb">>}
    ],

    %% Parser end-to-end: the declared param names must land in the agent config's :params map.
    AgentSrc = <<"module jpt\n  agent A\n    model \"ollama:m\"\n",
                 "    ask analyze(code: String, lang: String) -> {x: Int}\n",
                 "    ask summarize(text)\n  end\nend\n">>,
    ok = file:write_file("/tmp/jpt.jet", AgentSrc),
    _ = os:cmd("./jet /tmp/jpt.jet"),
    load_beam("/tmp/jpt.beam", jpt),
    {'__jet_actor_return__', {jet_agent_async, ACfg, _, _, _, _}, _} =
        jpt:'_A_instance_method_analyze'(#{}, <<"a">>, <<"b">>),
    Params = maps:get(params, ACfg, #{}),
    Parser = [
      {"parser: analyze param names",   maps:get(analyze, Params, undef),   ["code", "lang"]},
      {"parser: summarize param names", maps:get(summarize, Params, undef), ["text"]}
    ],

    Fails = run(Runtime ++ Parser),
    Total = length(Runtime) + length(Parser),
    case Fails of
      0 -> io:format("~nall ~p prompt-format tests passed~n", [Total]), halt(0);
      _ -> io:format("~n~p of ~p test(s) FAILED~n", [Fails, Total]), halt(1)
    end.

load_beam(Path, Mod) ->
    {ok, Bin} = file:read_file(Path),
    {module, Mod} = code:load_binary(Mod, atom_to_list(Mod) ++ ".beam", Bin).

run(Cases) ->
    lists:foldl(fun({Name, Got, Want}, Acc) ->
        case Got =:= Want of
          true  -> io:format("ok    ~s~n", [Name]), Acc;
          false -> io:format("FAIL  ~s~n  got:  ~p~n  want: ~p~n", [Name, Got, Want]), Acc + 1
        end
    end, 0, Cases).
