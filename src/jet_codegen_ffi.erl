-module(jet_codegen_ffi).
-export([
    erl_receive_expr_timeout/3,
    erl_binary_field2/2,
    erl_binary_field3/3,
    erl_record_field2/2,
    erl_function_name_str/1,
    erl_function_arity_int/1,
    erl_function_name_node/1,
    do_compile_forms/1,
    make_clause/3
]).

erl_receive_expr_timeout(Clauses, Timeout, Actions) ->
    erl_syntax:receive_expr(Clauses, Timeout, Actions).

erl_binary_field2(Value, Types) ->
    erl_syntax:binary_field(Value, Types).

erl_binary_field3(Value, Size, Types) ->
    erl_syntax:binary_field(Value, Size, Types).

erl_record_field2(Name, Value) ->
    erl_syntax:record_field(Name, Value).

erl_function_name_str(FuncSyntax) ->
    NameNode = erl_syntax:function_name(FuncSyntax),
    atom_to_binary(erl_syntax:atom_value(NameNode), utf8).

erl_function_arity_int(FuncSyntax) ->
    erl_syntax:function_arity(FuncSyntax).

erl_function_name_node(FuncSyntax) ->
    erl_syntax:function_name(FuncSyntax).

%% Create a clause with properly wrapped guards
%% Guards: [] -> no guards, [G1, G2, ...] -> conjunction [[G1, G2, ...]]
make_clause(Patterns, Guards, Body) ->
    WrappedGuards = case Guards of
        [] -> [];
        _ -> [Guards]
    end,
    erl_syntax:clause(Patterns, WrappedGuards, Body).

do_compile_forms(Forms) ->
    RevertedForms = [erl_syntax:revert(F) || F <- Forms],
    case compile:forms(RevertedForms, [return_errors, return_warnings]) of
        {ok, Module, Binary} ->
            {ok, {Module, Binary}};
        {ok, Module, Binary, _Warnings} ->
            {ok, {Module, Binary}};
        {error, Errors, _Warnings} ->
            {error, list_to_binary(lists:flatten(io_lib:format("~p", [Errors])))}
    end.
