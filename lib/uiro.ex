defmodule Uiro do

  def main(args) do
    {options, targets, _} = OptionParser.parse(args, aliases: [r: :run])
    module_file_path = List.first(targets)
    module_name = String.to_char_list(Path.basename(module_file_path, ".u"))
    {:ok, source} = File.read(module_file_path)
    {:ok, module_atom, binary} = Parser.parse(source, module_name)
                                 |> Compiler.to_erl_syntax_list(%{}, [])
                                 |> Compiler.to_erl_form_list
    binary_to_path({module_name, binary}, Path.dirname(module_file_path))
    if options[:run] do
      [module_name, func_name] = String.split(options[:run], "::")
      apply(String.to_atom(module_name), String.to_atom(func_name), [])
    end
  end

  defp binary_to_path({module_name, binary}, compile_path) do
    path = :filename.join(compile_path, module_name ++ '.beam')
    :ok = :file.write_file(path, binary)
  end

  defp parse_erl(text) do
    {:ok, tokens, _line} = :erl_scan.string(text)
    {:ok, tree} = :erl_parse.parse_exprs(tokens)
    tree
  end
end
