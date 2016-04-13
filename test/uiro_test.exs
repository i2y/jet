defmodule UiroTest do
  use ExUnit.Case
  doctest Uiro

  test "lexer case 1" do
    source = "aiueo"
    {:ok, tokens, _} = source |> String.to_char_list
                              |> :lexer.string
    assert [{:name, 1, 'aiueo'}] = tokens
  end

  test "lexer case 2" do
    source = "not"
    {:ok, tokens, _} = source |> String.to_char_list
                              |> :lexer.string
    assert [op_not: 1] = tokens
  end

  test "parser case 1" do
    source = "module abc export foo/2 fun foo(x, y) { [#foo, [1.0, x], [#bar, [y, 3]]] }"
    {:ok, tokens, _} = source |> String.to_char_list
                              |> :lexer.string
    {:ok, result} = :parser.parse(tokens)
    assert result == [[:module, {:name, 1, 'abc'}],
                      [:export, [[:fun_name, {:name, 1, 'foo'}, {:int, 1, 2}]]],
                      [:func, {:name, 1, 'foo'}, [[:name, {:name, 1, 'x'}], [:name, {:name, 1, 'y'}]],
                        [[:list, {:atom, 1, :foo},
                         [:list, {:float, 1, 1.0}, [:name, {:name, 1, 'x'}]],
                          [:list, {:atom, 1, :bar}, [:list, [:name, {:name, 1, 'y'}], {:int, 1, 3}]]]]]]
   end

  test "compiler case 1" do
    {:ok, mod, bin1} = Compiler.compile_dummy([])
    :code.load_binary(mod, [], bin1)
    assert :dummy.divide(10, 5) == 2
  end

  test "to_erl_syntax case 1" do
    :erl_syntax.atom(:foo) |> :erl_syntax.set_pos(1)
     == Compiler.to_erl_syntax({:atom, 1, :foo})
  end
end
