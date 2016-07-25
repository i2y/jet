defmodule Parser do
  @moduledoc false

  def parse(str, module_name) do
    {:ok, tokens, _} = str |> to_char_list |> :lexer.string
    # IO.inspect (tokens |> token_filter(module_name)), limit: 1000
    {:ok, list} = tokens |> token_filter(module_name) |> :parser.parse
    list
  end

  defp token_filter(tokens, module_name) do
    module_body = Enum.reverse(Enum.reduce(tokens, [], fn(token, acc) ->
      r_token = case token do
        {:name, line, '__name__'} -> {:atom, line, module_name}
        _ -> token
      end

      cond do
        acc == nil ->
          [r_token]
        infix_operator?(token) ->
          [r_token|remove_pre_newlines(acc)]
        newline?(r_token) and comma_or_infix_operator?(last_token(acc)) ->
          acc
        true ->
          [r_token|acc]
      end
    end))
    module_body
  end

  defp infix_operator?(token) do
    Enum.member?([:op_append, :op_plus, :op_minus, :op_times,
                  :op_div, :op_append, :op_leq, :op_geq,
                  :op_eq, :op_neq, :op_lt, :op_gt,
                  :op_and, :op_or, :op_is, :op_not,
                  :bang, :equals, :pipe, :pipeline,
                  :last_pipeline, :for, :in, :thin_arrow,
                  :fat_arrow, :dot, :cons], token_type(token))
  end

  defp comma?(token) do
    token_type(token) == :comma
  end

  defp comma_or_infix_operator?(token) do
    comma?(token) or infix_operator?(token)
  end

  defp newline?(token) do
    token_type(token) == :newline
  end

  defp token_type(nil) do
    nil
  end

  defp token_type(token) do
    elem(token, 0)
  end

  defp last_token(acc) do
    List.first(acc)
  end

  defp remove_pre_newlines(acc) do
    cond do
      newline?(List.first(acc)) ->
        [newline|rest] = acc
        remove_pre_newlines(rest)
      true ->
        acc
    end
  end
end
