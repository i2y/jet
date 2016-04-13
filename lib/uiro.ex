defmodule Uiro do

  def main(args) do
    #IO.inspect parse_erl('-record(item, {id}).')
    #IO.inspect parse_erl('lists:filter(fun(Item) -> false end, [1, 2, 3]).')
    #IO.inspect parse_erl('M\#{ key := val }.')
    #IO.inspect parse_erl('-aiueo(1, 2).')
    module_file_path = List.first(args)
    module_name = String.to_char_list(Path.basename(module_file_path, ".u"))
    {:ok, source} = File.read(module_file_path)
    {:ok, module_atom, binary} = Parser.parse(source, module_name)
                                    |> Compiler.to_erl_syntax(%{})
                                    |> Compiler.to_erl_form_list
    #IO.inspect :lists.nth(1, Compiler.module_behavior(binary)).behaviour_info(:callbacks)
    #IO.inspect Compiler.module_exports(binary)
    binary_to_path({module_name, binary}, '.')
  end

  defp binary_to_path({module_name, binary}, compile_path) do
    path = :filename.join(compile_path, module_name ++ '.beam')
    :ok = :file.write_file(path, binary)
  end

  defp parse_erl(text) do
    {:ok, tokens, _line} = :erl_scan.string(text)
    {:ok, tree} = :erl_parse.parse_exprs(tokens)
    #{:ok, tree} = :erl_parse.parse_form(tokens)
    tree
  end

end
