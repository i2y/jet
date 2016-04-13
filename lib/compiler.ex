defmodule Compiler do
  @moduledoc false

  import :erl_syntax

  def module_behaviour(file) do
    module_attr(file, :behaviour)
  end

  def module_exports(file) do
    case :beam_lib.chunks(file, [:exports]) do
      {:ok, {_module, [{:exports, export_funcs}]}} ->
        export_funcs
      _ ->
        exit(:bad_file)
    end
  end

  defp module_attr(file, key) do
    case :beam_lib.chunks(file, [:attributes]) do
      {:ok, {_module, [{:attributes, attr_list}]}} ->
        case lookup(key, attr_list) do
          {:ok, val} ->
            val
          _ ->
            :not_found
        end
      _ ->
        exit(:bad_file)
    end
  end

  defp lookup(key, [{key, val}|_]) do {:ok, val} end
  defp lookup(key, [_|tail]) do lookup(key, tail) end
  defp lookup(_, []) do :error end

  def put_func(uiro_syntax, func_map) do
    func_syntax = to_erl_syntax(uiro_syntax)
    signature = {function_name(func_syntax), function_arity(func_syntax)}
    if Dict.has_key?(func_map, signature) do
      prev_func_syntax = Dict.get(func_map, signature)
      merged_func_syntax =
        function(function_name(func_syntax),
                 function_clauses(prev_func_syntax) ++ [List.first(function_clauses(func_syntax))])
      Dict.put(func_map, signature, merged_func_syntax)
    else
      Dict.put(func_map, signature, func_syntax)
    end
  end

  def put_patterns(patterns_uiro_ast) do
    [:patterns, patterns_name, patterns] = patterns_uiro_ast
    :erlang.put(patterns_name, patterns)
  end

  def to_erl_form_list(syntax_list) do
    Enum.map(syntax_list, &revert(&1)) |> :compile.forms()
  end

  # TODO tail_recursion
  def to_erl_syntax([uiro_syntax | uiro_syntax_list], func_map) do
    case uiro_syntax do
      [:func|_] -> to_erl_syntax(uiro_syntax_list, put_func(uiro_syntax, func_map))
      [:patterns|_] ->
        put_patterns(uiro_syntax)
        to_erl_syntax(uiro_syntax_list, func_map)
      _ -> [to_erl_syntax(uiro_syntax) | to_erl_syntax(uiro_syntax_list, func_map)] # TODO
    end
  end

  def to_erl_syntax([], func_map) do
    Dict.values(func_map)
  end

  def to_erl_syntax([{:module_keyword, line}, name]) do
    {_, _, name_chars} = name
    attribute(atom(:module), [atom(name_chars)])
    |> set_pos(line)
  end

  def to_erl_syntax([{:class_keyword, line}, name]) do
    {_, _, name_chars} = name
    attribute(atom(:module), [atom(name_chars)])
    |> set_pos(line)
  end

  def to_erl_syntax([{:export_keyword, line}, func_names]) do
    attribute(atom(:export), [list(Enum.map(func_names, &Compiler.to_erl_syntax(&1)))])
    |> set_pos(line)
  end

  def to_erl_syntax([{:export_all, line}]) do
    attribute(atom(:compile), [atom(:export_all)])
    |> set_pos(line)
  end

  def to_erl_syntax([{:from_import, line},
                     {:name, module_name_line, module_name},
                     func_names]) do
    attribute(set_pos(atom(:import), line),
                  [set_pos(atom(module_name), module_name_line),
                   list(Enum.map(func_names, &Compiler.to_erl_syntax(&1)))])
    |> set_pos(line)
  end

  def to_erl_syntax([{:behavior, line}, name]) do
    to_erl_syntax([{:behaviour, line}, name])
  end

  def to_erl_syntax([{:behaviour, line}, name]) do
    {_, _, name_chars} = name
    attribute(set_pos(atom(:behaviour), line),
              [set_pos(atom(name_chars), line)])
    |> set_pos(line)
  end

  def to_erl_syntax([:attr, {:name, line, attr_name}, args]) do
    attribute(atom(attr_name) |> set_pos(line), [list(Enum.map(args, &Compiler.to_erl_syntax(&1)))])
    |> set_pos(line)
  end

  def to_erl_syntax([:fun_name, {:name, name_line, name}, {:int, arity_line, arity}]) do
    arity_qualifier(atom(name) |> set_pos(name_line),
                    integer(arity) |> set_pos(arity_line))
    |> set_pos(name_line)
  end

  def to_erl_syntax([:get_func, {:name, name_line, func_name}, {:int, arity_line, arity}]) do
    implicit_fun(arity_qualifier(atom(func_name) |> set_pos(name_line),
                                 integer(arity) |> set_pos(arity_line)))
    |> set_pos(name_line)
  end

  def to_erl_syntax([:get_func,
                     {:name, module_name_line, module_name},
                     {:name, func_name_line, func_name},
                     {:int, arity_line, arity}]) do
    implicit_fun(module_qualifier(atom(module_name) |> set_pos(module_name_line),
                                  arity_qualifier(atom(func_name) |> set_pos(func_name_line),
                                                  integer(arity) |> set_pos(arity_line)))
                 |> set_pos(module_name_line))
    |> set_pos(module_name_line)
  end

  def to_erl_syntax([:name, {:name, line, name}]) do
    variable(name) |> set_pos(line)
  end

  def pattern_to_erl_syntax([:name, {:name, line, name}]) do
    to_erl_syntax([:name, {:name, line, name}])
  end

  def to_erl_syntax([:func, name, args, body]) do
    clause1 = clause(Enum.map(args, &Compiler.pattern_to_erl_syntax(&1)),
                     [],
                     Enum.map(body, &Compiler.to_erl_syntax(&1)))
    {:name, line, func_name} = name
    function(atom(func_name), [set_pos(clause1, line)])
    |> set_pos(line)
  end

  def to_erl_syntax([:func, {:name, line, func_name}, args, guards, body]) do
    clause1 = clause(Enum.map(args, &Compiler.pattern_to_erl_syntax(&1)),
                     Enum.map(guards, &Compiler.to_erl_syntax(&1)),
                     Enum.map(body, &Compiler.to_erl_syntax(&1)))
    function(atom(func_name), [set_pos(clause1, line)])
    |> set_pos(line)
  end

  def to_erl_syntax([:func, clauses]) do
    fun_expr(Enum.map(clauses, &Compiler.to_erl_syntax(&1)))
  end

  def to_erl_syntax([:func, args, body]) do
    clause1 = clause(Enum.map(args, &Compiler.pattern_to_erl_syntax(&1)),
                     [],
                     Enum.map(body, &Compiler.to_erl_syntax(&1)))
    fun_expr([clause1])
  end

  def to_erl_syntax([:func, args, guards, body]) do
    clause1 = clause(Enum.map(args, &Compiler.pattern_to_erl_syntax(&1)),
                     Enum.map(guards, &Compiler.to_erl_syntax(&1)),
                     Enum.map(body, &Compiler.to_erl_syntax(&1)))
    fun_expr([clause1])
  end

  def to_erl_syntax([{:receive_keyword, line}, clauses]) do
    receive_expr(Enum.map(clauses, &Compiler.to_erl_syntax(&1)))
    |> set_pos(line)
  end

  def match_patterns(patterns_name, clauses) do
    # TODO
    # プロセス辞書からpatternsを取り出す。
    # TODO patternsの入れ子パターンを展開する。
    # clausesからパターン部分のみを取り出す。
    # 両者が一致するかいなかを試す。一致しなかったらエラー。
  end

  def to_erl_syntax([{:receive_keyword, line}, patterns_name, clauses, timeout, actions]) do
    match_patterns(patterns_name, clauses) # TODO
    to_erl_syntax([{:receive_keyword, line}, clauses, timeout, actions])
  end

  def to_erl_syntax([{:receive_keyword, line}, clauses, timeout, actions]) do
    receive_expr(Enum.map(clauses, &Compiler.to_erl_syntax(&1)),
                 to_erl_syntax(timeout),
                 Enum.map(actions, &Compiler.to_erl_syntax(&1)))
    |> set_pos(line)
  end

  def to_erl_syntax([{:match_keyword, line}, value, patterns_name, clauses]) do
    match_patterns(patterns_name, clauses) # TODO
    to_erl_syntax([{:match_keyword, line}, value, clauses])
  end

  def to_erl_syntax([{:match_keyword, line}, value, clauses]) do
    case_expr(to_erl_syntax(value), Enum.map(clauses, &Compiler.to_erl_syntax(&1)))
    |> set_pos(line)
  end

  def to_erl_syntax([:case_clause, patterns, body]) do
    clause(Enum.map(patterns, &Compiler.pattern_to_erl_syntax(&1)),
           [],
           Enum.map(body, &Compiler.to_erl_syntax(&1)))
  end

  def to_erl_syntax([:case_clause, patterns, guards, body]) do
    clause(Enum.map(patterns, &Compiler.pattern_to_erl_syntax(&1)),
           Enum.map(guards, &Compiler.to_erl_syntax(&1)),
           Enum.map(body, &Compiler.to_erl_syntax(&1)))
  end

  def to_erl_syntax([{:if_keyword, line}, condition, body]) do
    case_expr(to_erl_syntax(condition),
              [clause([atom(:false)],
                      [],
                      [:erl_syntax.nil()]),
               clause([atom(:nil)],
                      [],
                      [:erl_syntax.nil()]),
               clause([variable(:_)],
                      [],
                      Enum.map(body, &Compiler.to_erl_syntax(&1)))])
    |> set_pos(line)
  end

  def to_erl_syntax([{:if_keyword, line}, condition, true_body, false_body]) do
    case_expr(to_erl_syntax(condition),
              [clause([atom(:false)],
                      [],
                      Enum.map(false_body, &Compiler.to_erl_syntax(&1))),
               clause([atom(:nil)],
                      [],
                      Enum.map(false_body, &Compiler.to_erl_syntax(&1))),
               clause([variable(:_)],
                      [],
                      Enum.map(true_body, &Compiler.to_erl_syntax(&1)))])
    |> set_pos(line)
  end

  def to_erl_syntax([{:op_plus, line}, arg1, arg2]) do
    infix_expr(to_erl_syntax(arg1), operator('+'), to_erl_syntax(arg2))
        |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:op_plus, line}, arg1, arg2]) do
    infix_expr(pattern_to_erl_syntax(arg1),
               operator('+'),
               pattern_to_erl_syntax(arg2))
      |> set_pos(line)
  end

  def to_erl_syntax([{:op_minus, line}, arg1, arg2]) do
    infix_expr(to_erl_syntax(arg1), operator('-'), to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:op_minus, line}, arg1, arg2]) do
    infix_expr(pattern_to_erl_syntax(arg1),
               operator('-'),
               pattern_to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def to_erl_syntax([{:op_times, line}, arg1, arg2]) do
    infix_expr(to_erl_syntax(arg1), operator('*'), to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:op_times, line}, arg1, arg2]) do
    infix_expr(pattern_to_erl_syntax(arg1),
               operator('*'),
               pattern_to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def to_erl_syntax([{:op_div, line}, arg1, arg2]) do
    infix_expr(to_erl_syntax(arg1), operator('/'), to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:op_div, line}, arg1, arg2]) do
    infix_expr(pattern_to_erl_syntax(arg1),
               operator('/'),
               pattern_to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def to_erl_syntax([{:op_floordiv, line}, arg1, arg2]) do
    infix_expr(to_erl_syntax(arg1), operator('div'), to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:op_floordiv, line}, arg1, arg2]) do
    infix_expr(pattern_to_erl_syntax(arg1),
               operator('div'),
               pattern_to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def to_erl_syntax([{:percent, line}, arg1, arg2]) do
    infix_expr(to_erl_syntax(arg1), operator('rem'), to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:percent, line}, arg1, arg2]) do
    infix_expr(pattern_to_erl_syntax(arg1),
               operator('rem'),
               pattern_to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def to_erl_syntax([{:op_append, line}, arg1, arg2]) do
    infix_expr(to_erl_syntax(arg1), operator('++'), to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:op_append, line}, arg1, arg2]) do
    infix_expr(pattern_to_erl_syntax(arg1),
               operator('++'),
               pattern_to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def to_erl_syntax([{:op_leq, line}, arg1, arg2]) do
    infix_expr(to_erl_syntax(arg1), operator('=<'), to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:op_leq, line}, arg1, arg2]) do
    infix_expr(pattern_to_erl_syntax(arg1),
               operator('=<'),
               pattern_to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def to_erl_syntax([{:op_geq, line}, arg1, arg2]) do
    infix_expr(to_erl_syntax(arg1), operator('>='), to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:op_geq, line}, arg1, arg2]) do
    infix_expr(pattern_to_erl_syntax(arg1),
               operator('>='),
               pattern_to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def to_erl_syntax([{:op_eq, line}, arg1, arg2]) do
    infix_expr(to_erl_syntax(arg1), operator('=='), to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:op_eq, line}, arg1, arg2]) do
    infix_expr(pattern_to_erl_syntax(arg1),
               operator('=='),
               pattern_to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def to_erl_syntax([{:op_neq, line}, arg1, arg2]) do
    infix_expr(to_erl_syntax(arg1), operator('/='), to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:op_neq, line}, arg1, arg2]) do
    infix_expr(pattern_to_erl_syntax(arg1),
               operator('/='),
               pattern_to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def to_erl_syntax([{:op_lt, line}, arg1, arg2]) do
    infix_expr(to_erl_syntax(arg1), operator('<'), to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:op_lt, line}, arg1, arg2]) do
    infix_expr(pattern_to_erl_syntax(arg1),
               operator('<'),
               pattern_to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def to_erl_syntax([{:op_gt, line}, arg1, arg2]) do
    infix_expr(to_erl_syntax(arg1), operator('>'), to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:op_gt, line}, arg1, arg2]) do
    infix_expr(pattern_to_erl_syntax(arg1),
               operator('>'),
               pattern_to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def to_erl_syntax([{:op_and, line}, arg1, arg2]) do
    infix_expr(to_erl_syntax(arg1), operator('andalso'), to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:op_and, line}, arg1, arg2]) do
    infix_expr(pattern_to_erl_syntax(arg1),
               operator('andalso'),
               pattern_to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def to_erl_syntax([{:op_or, line}, arg1, arg2]) do
    infix_expr(to_erl_syntax(arg1), operator('orelse'), to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:op_or, line}, arg1, arg2]) do
    infix_expr(pattern_to_erl_syntax(arg1),
               operator('orelse'),
               pattern_to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def to_erl_syntax([{:op_xor, line}, arg1, arg2]) do
    infix_expr(to_erl_syntax(arg1), operator('xor'), to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:op_xor, line}, arg1, arg2]) do
    infix_expr(pattern_to_erl_syntax(arg1),
               operator('xor'),
               pattern_to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def to_erl_syntax([{:op_bitand, line}, arg1, arg2]) do
    infix_expr(to_erl_syntax(arg1), operator('bitand'), to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:op_bitand, line}, arg1, arg2]) do
    infix_expr(pattern_to_erl_syntax(arg1),
               operator('bitand'),
               pattern_to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def to_erl_syntax([{:op_bitor, line}, arg1, arg2]) do
    infix_expr(to_erl_syntax(arg1), operator('bitor'), to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:op_bitor, line}, arg1, arg2]) do
    infix_expr(pattern_to_erl_syntax(arg1),
               operator('bitor'),
               pattern_to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def to_erl_syntax([{:op_bitxor, line}, arg1, arg2]) do
    infix_expr(to_erl_syntax(arg1), operator('bitxor'), to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:op_bitxor, line}, arg1, arg2]) do
    infix_expr(pattern_to_erl_syntax(arg1),
               operator('bitxor'),
               pattern_to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def to_erl_syntax([{:op_bitsl, line}, arg1, arg2]) do
    infix_expr(to_erl_syntax(arg1),
               operator('bitsl'),
               to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:op_bitsl, line}, arg1, arg2]) do
    infix_expr(pattern_to_erl_syntax(arg1),
               operator('bitsl'),
               pattern_to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def to_erl_syntax([{:op_bitsr, line}, arg1, arg2]) do
    infix_expr(to_erl_syntax(arg1), operator('bitsr'), to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:op_bitsr, line}, arg1, arg2]) do
    infix_expr(pattern_to_erl_syntax(arg1),
               operator('bitsr'),
               pattern_to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def to_erl_syntax([{:bang, line}, arg1, arg2]) do
    infix_expr(to_erl_syntax(arg1), operator('!'), to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:bang, line}, arg1, arg2]) do
    infix_expr(pattern_to_erl_syntax(arg1),
               operator('!'),
               pattern_to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def to_erl_syntax([{:colon_colon, line}, map, {:name, _, key}]) do
    operator = module_qualifier(atom(:maps), atom(:get))
    application(operator, [atom(key), to_erl_syntax(map)])
    |> set_pos(line)
  end

  def to_erl_syntax([{:call_method, line}, obj, {:name, _, method_name}, args]) do
    operator = module_qualifier(atom(:uiro_runtime), atom(:call_method))
    compiled_args = Enum.map(args, &Compiler.to_erl_syntax(&1))
    application(operator, [to_erl_syntax(obj), atom(method_name), list(compiled_args)])
    |> set_pos(line)
  end

  def to_erl_syntax([{:new, line}, {:name, _, module_name}, args]) do
    operator = module_qualifier(atom(:uiro_runtime), atom(:new_object))
    compiled_args = Enum.map(args, &Compiler.to_erl_syntax(&1))
    application(operator, [atom(module_name), list(compiled_args)])
    |> set_pos(line)
  end

  def to_erl_syntax([{:op_not, line}, arg]) do
    prefix_expr(operator('not'), to_erl_syntax(arg))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:op_not, line}, arg]) do
    prefix_expr(operator('not'), pattern_to_erl_syntax(arg))
    |> set_pos(line)
  end

  def to_erl_syntax([{:op_bnot, line}, arg]) do
    prefix_expr(operator('bnot'), to_erl_syntax(arg))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:op_bnot, line}, arg]) do
    prefix_expr(operator('bnot'), pattern_to_erl_syntax(arg))
    |> set_pos(line)
  end

  def to_erl_syntax([{:pipeline, line}, first_arg, [:apply, operator, args]]) do
    to_erl_syntax([:apply, operator, [first_arg|args]])
    |> set_pos(line)
  end

  def to_erl_syntax([{:last_pipeline, line}, last_arg, [:apply, operator, args]]) do
    to_erl_syntax([:apply, operator, args ++ [last_arg]])
    |> set_pos(line)
  end

  def to_erl_syntax([{:equals, line}, arg1, arg2]) do
    match_expr(pattern_to_erl_syntax(arg1), to_erl_syntax(arg2))
    |> set_pos(line)
  end

  def to_erl_syntax([:list | rest]) do
    list(Enum.map(rest, &Compiler.to_erl_syntax(&1)))
  end

  def pattern_to_erl_syntax([:list | rest]) do
    list(Enum.map(rest, &Compiler.pattern_to_erl_syntax(&1)))
  end

  def to_erl_syntax([:cons, head, tail]) do
    cons(to_erl_syntax(head), to_erl_syntax(tail))
  end

  def pattern_to_erl_syntax([:cons, head, tail]) do
    cons(pattern_to_erl_syntax(head), pattern_to_erl_syntax(tail))
  end

  def to_erl_syntax(:nil) do
    :erl_syntax.nil()
  end

  def pattern_to_erl_syntax(:nil) do
    :erl_syntax.nil()
  end

  def to_erl_syntax([:tuple | rest]) do
    tuple(Enum.map(rest, &Compiler.to_erl_syntax(&1)))
  end

  def pattern_to_erl_syntax([:tuple | rest]) do
    tuple(Enum.map(rest, &Compiler.pattern_to_erl_syntax(&1)))
  end

  def to_erl_syntax([:map, map_fields]) do
    map_expr(Enum.map(map_fields, &Compiler.to_erl_syntax(&1)))
  end

  def to_erl_syntax([:map_field, key, value]) do
    map_field_assoc(to_erl_syntax(key), to_erl_syntax(value))
  end

  def to_erl_syntax([:map_field_atom, {:name, line, key}, value]) do
    map_field_assoc(set_pos(atom(key), line), to_erl_syntax(value))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([:map, map_fields]) do
    map_expr(Enum.map(map_fields, &Compiler.pattern_to_erl_syntax(&1)))
  end

  def pattern_to_erl_syntax([:map_field, key, value]) do
    map_field_exact(pattern_to_erl_syntax(key),
                    pattern_to_erl_syntax(value))
  end

  def pattern_to_erl_syntax([:map_field_atom, {:name, line, key}, value]) do
    map_field_exact(set_pos(atom(key), line),
                    pattern_to_erl_syntax(value))
    |> set_pos(line)
  end

  def to_erl_syntax([:ref_attr, {:name, line, name}]) do
    operator = module_qualifier(atom(:maps), atom(:get))
    application(operator,
                [atom(name),
                 application(operator,
                             [atom(:__state__),
                              variable(:self) |> set_pos(line)])
                 |> set_pos(line)])
    |> set_pos(line)
  end

  def to_erl_syntax([{:record_def, line}, {:name, name_line, name}, record_fields]) do
    attribute(set_pos(atom(:record), line),
              [set_pos(atom(name), name_line),
               tuple(Enum.map(record_fields, &Compiler.to_erl_syntax(&1)))])
    |> set_pos(line)
  end

  def to_erl_syntax([{:record, line}, {:name, name_line, name}, record_fields]) do
    record_expr(set_pos(atom(name), name_line),
                Enum.map(record_fields, &Compiler.to_erl_syntax(&1)))
    |> set_pos(line)
  end

  def to_erl_syntax([:record_field, {:name, name_line, name}]) do
    record_field(set_pos(atom(name), name_line))
    |> set_pos(name_line)
  end

  def to_erl_syntax([:record_field, {:name, name_line, name}, value]) do
    record_field(set_pos(atom(name), name_line),
                 to_erl_syntax(value))
    |> set_pos(name_line)
  end

  def pattern_to_erl_syntax([{:record, line}, {:name, name_line, name}, record_fields]) do
    record_expr(set_pos(atom(name), name_line),
                Enum.map(record_fields, &Compiler.pattern_to_erl_syntax(&1)))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([:record_field, {:name, name_line, name}]) do
    record_field(set_pos(atom(name), name_line))
    |> set_pos(name_line)
  end

  def pattern_to_erl_syntax([:record_field, {:name, name_line, name}, value]) do
    record_field(set_pos(atom(name), name_line),
                 pattern_to_erl_syntax(value))
    |> set_pos(name_line)
  end

  def to_erl_syntax([:record_field_index,
                     {:name, record_name_line, record_name},
                     {:name, record_field_line, record_field}]) do
    record_index_expr(set_pos(atom(record_name), record_name_line),
                      set_pos(atom(record_field), record_field_line))
    |> set_pos(record_name_line)
  end

  def to_erl_syntax([{:list_comp, line}, template, generators]) do
    list_comp(to_erl_syntax(template),
              Enum.map(generators, &Compiler.to_erl_syntax(&1)))
    |> set_pos(line)
  end

  def to_erl_syntax([{:list_comp, line}, template, generators, guard]) do
    list_comp(to_erl_syntax(template),
              Enum.map(generators, &Compiler.to_erl_syntax(&1))
               ++ [to_erl_syntax(guard)])
    |> set_pos(line)
  end

  def to_erl_syntax([{:binary_comp, line}, template, generators]) do
    binary_comp(to_erl_syntax(template),
                Enum.map(generators, &Compiler.to_erl_syntax(&1)))
    |> set_pos(line)
  end

  def to_erl_syntax([{:binary_comp, line}, template, generators, guard]) do
    binary_comp(to_erl_syntax(template),
                Enum.map(generators, &Compiler.to_erl_syntax(&1))
                 ++ [to_erl_syntax(guard)])
    |> set_pos(line)
  end

  def to_erl_syntax([{:list_generator, line}, pattern, body]) do
    generator(pattern_to_erl_syntax(pattern), to_erl_syntax(body))
    |> set_pos(line)
  end

  def to_erl_syntax([{:binary_generator, line}, pattern, body]) do
    binary_generator(pattern_to_erl_syntax(pattern), to_erl_syntax(body))
    |> set_pos(line)
  end

  def to_erl_syntax([:apply, expr, args]) do
    operator = to_erl_syntax(expr)
    compiled_args = Enum.map(args, &Compiler.to_erl_syntax(&1))
    application(operator, compiled_args)
    |> set_pos(get_pos(operator))
  end

  def to_erl_syntax([:func_ref, {:name, line, module_name},
                                {:name, _, func_name}]) do
    module_qualifier(atom(module_name), atom(func_name))
    |> set_pos(line)
  end

  def to_erl_syntax([:func_ref, {:name, line, func_name}]) do
    atom(func_name) |> set_pos(line)
  end

  def to_erl_syntax([:func_ref, {:str, line, module_name},
                                {:name, _, func_name}]) do
    last_index = Enum.count(module_name) - 2
    m_name = module_name |> Enum.slice(1..last_index)
    module_qualifier(atom(m_name), atom(func_name))
    |> set_pos(line)
  end

  def to_erl_syntax([:func_ref, tuple, {:name, line, func_name}]) do
    module_qualifier(to_erl_syntax(tuple), atom(func_name))
    |> set_pos(line)
  end

  def to_erl_syntax([:func_ref, expr]) do
    to_erl_syntax(expr)
  end

  def to_erl_syntax({:atom, line, value}) do
    atom(value) |> set_pos(line)
  end

  def pattern_to_erl_syntax({:atom, line, value}) do
    atom(value) |> set_pos(line)
  end

  def to_erl_syntax({:int, line, value}) do
    integer(value) |> set_pos(line)
  end

  def pattern_to_erl_syntax({:int, line, value}) do
    integer(value) |> set_pos(line)
  end

  def to_erl_syntax({:float, line, value}) do
    float(value) |> set_pos(line)
  end

  def pattern_to_erl_syntax({:float, line, value}) do
    float(value) |> set_pos(line)
  end

  def to_erl_syntax({:str, line, value}) do
    last_index = Enum.count(value) - 2
    value |> Enum.slice(1..last_index)
          |> string()
          |> set_pos(line)
  end

  def pattern_to_erl_syntax({:str, line, value}) do
    last_index = Enum.count(value) - 2
    value |> Enum.slice(1..last_index)
          |> string()
          |> set_pos(line)
  end

  def to_erl_syntax([{:binary, line}]) do
    binary([]) |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:binary, line}]) do
    binary([]) |> set_pos(line)
  end

  def to_erl_syntax([{:binary, line}, binary_fields]) do
    binary(Enum.map(binary_fields, &Compiler.to_erl_syntax(&1)))
    |> set_pos(line)
  end

  def pattern_to_erl_syntax([{:binary, line}, binary_fields]) do
    binary(Enum.map(binary_fields, &Compiler.pattern_to_erl_syntax(&1)))
    |> set_pos(line)
  end

  def to_erl_syntax([:binary_field, value]) do
    binary_field(to_erl_syntax(value))
  end

  def pattern_to_erl_syntax([:binary_field, value]) do
    binary_field(pattern_to_erl_syntax(value))
  end

  def to_erl_syntax([:binary_field, value, types]) do
    binary_field(to_erl_syntax(value),
                 Enum.map(types, fn({:name, line, name}) ->
                   set_pos(atom(name), line)
                 end))
  end

  def pattern_to_erl_syntax([:binary_field, value, types]) do
    binary_field(pattern_to_erl_syntax(value),
                 Enum.map(types, fn({:name, line, name}) ->
                   set_pos(atom(name), line)
                 end))
  end

  def to_erl_syntax([:binary_field, value, size, :default]) do
    binary_field(to_erl_syntax(value),
                 to_erl_syntax(size),
                 [atom(:integer)])
  end

  def pattern_to_erl_syntax([:binary_field, value, size, :default]) do
    binary_field(pattern_to_erl_syntax(value),
                 pattern_to_erl_syntax(size), [atom(:integer)])
  end

  def to_erl_syntax([:binary_field, value, size, types]) do
    binary_field(to_erl_syntax(value),
                 to_erl_syntax(size),
                 Enum.map(types, fn({:name, line, name}) ->
                   set_pos(atom(name), line)
                 end))
  end

  def pattern_to_erl_syntax([:binary_field, value, size, types]) do
    binary_field(pattern_to_erl_syntax(value),
                 pattern_to_erl_syntax(size),
                 Enum.map(types, fn({:name, line, name}) ->
                   set_pos(atom(name), line)
                 end))
  end

  def to_erl_syntax({:nil, line}) do
    :erl_syntax.nil() |> set_pos(line)
  end

  def pattern_to_erl_syntax({:nil, line}) do
    :erl_syntax.nil() |> set_pos(line)
  end

  def to_erl_syntax({:true, line}) do
    atom(:true) |> set_pos(line)
  end

  def pattern_to_erl_syntax({:true, line}) do
    atom(:true) |> set_pos(line)
  end

  def to_erl_syntax({:false, line}) do
    atom(:false) |> set_pos(line)
  end

  def pattern_to_erl_syntax({:false, line}) do
    atom(:false) |> set_pos(line)
  end

end
