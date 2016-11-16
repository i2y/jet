defmodule Jet do

  def main(args) do
    {options, targets, _} = OptionParser.parse(args, aliases: [r: :run])
    module_file_path = List.first(targets)
    module_name = String.to_char_list(Path.basename(module_file_path, ".jet"))
    {:ok, source} = File.read(module_file_path)
    {:ok, module_atom, binary} = Parser.parse(source, module_name)
                                 |> Compiler.to_erl_syntax_list(%{}, [])
                                 |> Compiler.to_erl_form_list
    binary_to_path({module_name, binary}, Path.dirname(module_file_path))
    if options[:run] do
      [module_name, func_name] = String.split(options[:run], "::")
      apply(String.to_atom(module_name), String.to_atom(func_name), [])
    end
    # TODO
    # validate_protocol(:erlang.list_to_atom(module_name))
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

  defp validate_protocol(module_name) do
      Enum.map(List.flatten(:proplists.get_all_values(:include,
                                                      apply(module_name,
                                                            :module_info,
                                                            [:attributes]))),
               fn included_module ->
                 protocol_methods = :proplists.get_all_values(:protocol,
                                                              apply(included_module,
                                                                    :module_info,
                                                                    [:attributes])) |> List.flatten
                 exported_methods = apply(module_name, :module_info, [:exports])
                 excluded_proplists(protocol_methods, exported_methods)
                 |> Enum.map(fn {method_name, arity} ->
                               protocol_name = Atom.to_string(included_module)
                               IO.puts Atom.to_string(module_name)
                                       <> ": Warning: undefined "
                                       <> protocol_name
                                       <> " protocol method "
                                       <> Atom.to_string(method_name)
                                       <> "/"
                                       <> Integer.to_string(arity)
                             end)
               end)
    end

    defp excluded_proplists(proplists_1, proplists_2) do
      Enum.flat_map(proplists_1, fn prop ->
        {key, value} = prop
        case :proplists.lookup(key, proplists_2) do
          {^key, ^value} -> []
          _ -> [{key, value}]
        end
      end)
    end
end
