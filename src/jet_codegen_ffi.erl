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
    make_clause/3,
    erl_try_catch/4,
    erl_try_finally/2
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

%% try Body catch CatchVar -> ... [after After] end
%% The raw Class:Reason:Stacktrace is wrapped into an exception map via
%% jet_ffi:make_exception/3 and bound to the (lowercase) jet variable CatchVar.
%% CatchVar is passed as a binary and run through jet_ffi:erl_variable/1 so it
%% matches the capitalized Erlang variable the catch body already refers to.
erl_try_catch(Body, CatchVar, CatchBody, After) ->
    ClassV  = erl_syntax:variable('JetExClass'),
    ReasonV = erl_syntax:variable('JetExReason'),
    StackV  = erl_syntax:variable('JetExStack'),
    MakeExc = erl_syntax:application(
                erl_syntax:module_qualifier(erl_syntax:atom(jet_ffi),
                                            erl_syntax:atom(make_exception)),
                [ClassV, ReasonV, StackV]),
    Bind = erl_syntax:match_expr(jet_ffi:erl_variable(CatchVar), MakeExc),
    HandlerBody = [Bind | CatchBody],
    Pattern = erl_syntax:class_qualifier(ClassV, ReasonV, StackV),
    Handler = erl_syntax:clause([Pattern], none, HandlerBody),
    case After of
        [] -> erl_syntax:try_expr(Body, [Handler]);
        _  -> erl_syntax:try_expr(Body, [], [Handler], After)
    end.

%% try Body after After end   (finally, no catch)
erl_try_finally(Body, After) ->
    erl_syntax:try_after_expr(Body, After).

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
