-module(jet_ffi).
-export([
    erl_atom/1, erl_variable/1, erl_integer/1, erl_float/1, erl_string/1,
    erl_char/1, erl_nil/0, erl_cons/2, erl_list/1, erl_tuple/1,
    erl_application/2, erl_module_qualifier/2,
    erl_function/2, erl_clause/3, erl_fun_expr/1,
    erl_match_expr/2, erl_case_expr/2,
    erl_receive_expr/1, erl_receive_expr/3,
    erl_infix_expr/3, erl_prefix_expr/2,
    erl_attribute/2, erl_arity_qualifier/2,
    erl_map_expr/1, erl_map_field_assoc/2, erl_map_field_exact/2,
    erl_binary/1, erl_binary_field/1, erl_binary_field/2, erl_binary_field/3,
    erl_record_expr/2, erl_record_field/1, erl_record_field/2,
    erl_record_index_expr/2,
    erl_list_comp/2, erl_binary_comp/2,
    erl_generator/2, erl_binary_generator/2,
    erl_catch_expr/1, erl_implicit_fun/1,
    erl_operator/1,
    erl_revert/1, erl_set_pos/2,
    erl_function_name/1, erl_function_arity/1, erl_function_clauses/1,
    compile_forms/1, write_beam/2,
    string_to_atom/1, atom_to_string/1,
    charlist_to_string/1, string_to_charlist/1,
    module_exports/1, module_attributes/1,
    format_error/1,
    codepoint_to_string/1,
    actor_put/2
]).

%% erl_syntax constructors - accept Gleam-friendly types

erl_atom(Value) when is_binary(Value) ->
    erl_syntax:atom(binary_to_atom(Value, utf8));
erl_atom(Value) when is_atom(Value) ->
    erl_syntax:atom(Value).

erl_variable(Name) when is_binary(Name) ->
    %% Capitalize first letter for Erlang variable convention
    Charlist = binary_to_list(Name),
    ErlName = case Charlist of
        [H|_T] when H >= $a, H =< $z ->
            list_to_atom(capitalize(Charlist));
        [$_|_] ->
            list_to_atom(capitalize(Charlist));
        _ ->
            list_to_atom(Charlist)
    end,
    erl_syntax:variable(ErlName);
erl_variable(Name) when is_atom(Name) ->
    erl_syntax:variable(Name).

erl_integer(Value) ->
    erl_syntax:integer(Value).

erl_float(Value) ->
    erl_syntax:float(Value).

erl_string(Value) when is_binary(Value) ->
    erl_syntax:string(binary_to_list(Value));
erl_string(Value) when is_list(Value) ->
    erl_syntax:string(Value).

erl_char(Value) ->
    erl_syntax:char(Value).

erl_nil() ->
    erl_syntax:nil().

erl_cons(Head, Tail) ->
    erl_syntax:cons(Head, Tail).

erl_list(Elements) ->
    erl_syntax:list(Elements).

erl_tuple(Elements) ->
    erl_syntax:tuple(Elements).

erl_application(Operator, Arguments) ->
    erl_syntax:application(Operator, Arguments).

erl_module_qualifier(Module, Function) ->
    erl_syntax:module_qualifier(Module, Function).

erl_function(Name, Clauses) ->
    erl_syntax:function(Name, Clauses).

erl_clause(Patterns, Guards, Body) ->
    erl_syntax:clause(Patterns, Guards, Body).

erl_fun_expr(Clauses) ->
    erl_syntax:fun_expr(Clauses).

erl_match_expr(Pattern, Body) ->
    erl_syntax:match_expr(Pattern, Body).

erl_case_expr(Argument, Clauses) ->
    erl_syntax:case_expr(Argument, Clauses).

erl_receive_expr(Clauses) ->
    erl_syntax:receive_expr(Clauses).

erl_receive_expr(Clauses, Timeout, Actions) ->
    erl_syntax:receive_expr(Clauses, Timeout, Actions).

erl_infix_expr(Left, Operator, Right) ->
    erl_syntax:infix_expr(Left, Operator, Right).

erl_prefix_expr(Operator, Argument) ->
    erl_syntax:prefix_expr(Operator, Argument).

erl_attribute(Name, Args) ->
    erl_syntax:attribute(Name, Args).

erl_arity_qualifier(FunName, Arity) ->
    erl_syntax:arity_qualifier(FunName, Arity).

erl_map_expr(Fields) ->
    erl_syntax:map_expr(Fields).

erl_map_field_assoc(Key, Value) ->
    erl_syntax:map_field_assoc(Key, Value).

erl_map_field_exact(Key, Value) ->
    erl_syntax:map_field_exact(Key, Value).

erl_binary(Fields) ->
    erl_syntax:binary(Fields).

erl_binary_field(Value) ->
    erl_syntax:binary_field(Value).

erl_binary_field(Value, Types) ->
    erl_syntax:binary_field(Value, Types).

erl_binary_field(Value, Size, Types) ->
    erl_syntax:binary_field(Value, Size, Types).

erl_record_expr(RecordName, Fields) ->
    erl_syntax:record_expr(RecordName, Fields).

erl_record_field(Name) ->
    erl_syntax:record_field(Name).

erl_record_field(Name, Value) ->
    erl_syntax:record_field(Name, Value).

erl_record_index_expr(RecordName, FieldName) ->
    erl_syntax:record_index_expr(RecordName, FieldName).

erl_list_comp(Template, Qualifiers) ->
    erl_syntax:list_comp(Template, Qualifiers).

erl_binary_comp(Template, Qualifiers) ->
    erl_syntax:binary_comp(Template, Qualifiers).

erl_generator(Pattern, Body) ->
    erl_syntax:generator(Pattern, Body).

erl_binary_generator(Pattern, Body) ->
    erl_syntax:binary_generator(Pattern, Body).

erl_catch_expr(Expr) ->
    erl_syntax:catch_expr(Expr).

erl_implicit_fun(AQ) ->
    erl_syntax:implicit_fun(AQ).

erl_operator(Op) when is_binary(Op) ->
    erl_syntax:operator(binary_to_atom(Op, utf8));
erl_operator(Op) when is_atom(Op) ->
    erl_syntax:operator(Op).

erl_revert(Tree) ->
    erl_syntax:revert(Tree).

erl_set_pos(Tree, Line) ->
    erl_syntax:set_pos(Tree, Line).

erl_function_name(Tree) ->
    erl_syntax:function_name(Tree).

erl_function_arity(Tree) ->
    erl_syntax:function_arity(Tree).

erl_function_clauses(Tree) ->
    erl_syntax:function_clauses(Tree).

%% Compilation

compile_forms(Forms) ->
    RevertedForms = [erl_syntax:revert(F) || F <- Forms],
    case compile:forms(RevertedForms) of
        {ok, Module, Binary} ->
            {ok, Module, Binary};
        {ok, Module, Binary, _Warnings} ->
            {ok, Module, Binary};
        {error, Errors, _Warnings} ->
            {error, format_compile_errors(Errors)}
    end.

write_beam(Path, Binary) when is_binary(Path) ->
    file:write_file(binary_to_list(Path), Binary);
write_beam(Path, Binary) when is_list(Path) ->
    file:write_file(Path, Binary).

%% Utilities

string_to_atom(Str) when is_binary(Str) ->
    binary_to_atom(Str, utf8).

atom_to_string(Atom) when is_atom(Atom) ->
    atom_to_binary(Atom, utf8).

charlist_to_string(Chars) when is_list(Chars) ->
    list_to_binary(Chars).

string_to_charlist(Str) when is_binary(Str) ->
    binary_to_list(Str).

module_exports(ModuleName) when is_atom(ModuleName) ->
    case beam_lib:chunks(atom_to_list(ModuleName), [exports]) of
        {ok, {_, [{exports, Exports}]}} -> {ok, Exports};
        _ -> {error, bad_file}
    end.

module_attributes(ModuleName) when is_atom(ModuleName) ->
    case beam_lib:chunks(atom_to_list(ModuleName), [attributes]) of
        {ok, {_, [{attributes, Attrs}]}} -> {ok, Attrs};
        _ -> {error, bad_file}
    end.

format_error(Error) ->
    lists:flatten(io_lib:format("~p", [Error])).

%% Internal helpers

capitalize([]) -> [];
capitalize([H|T]) when H >= $a, H =< $z ->
    [H - 32 | T];
capitalize([$_|T]) ->
    [$_ | capitalize_after_underscore(T)];
capitalize(Other) -> Other.

capitalize_after_underscore([]) -> [];
capitalize_after_underscore([H|T]) when H >= $a, H =< $z ->
    [H - 32 | T];
capitalize_after_underscore(Other) -> Other.

format_compile_errors(Errors) ->
    lists:flatten(io_lib:format("~p", [Errors])).

codepoint_to_string(Code) ->
    unicode:characters_to_binary([Code]).

%% Actor @attr = expr helper: put and return the NEW value
actor_put(Key, Value) ->
    erlang:put(Key, Value),
    Value.
