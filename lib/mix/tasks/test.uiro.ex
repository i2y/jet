defmodule Mix.Tasks.Test.Uiro do
  use Mix.Task

  def run(_) do
    project = Mix.Project.config
    test_paths = project[:test_paths]
    if test_paths == nil do
      test_paths = ["test"]
    end
    Enum.map(test_paths, fn path -> :code.add_path(String.to_char_list(path)) end)
    files = Mix.Utils.extract_files(test_paths, "test_*.u")
    Mix.Tasks.Compile.Uiro.compile(files)
    module_names = Enum.map(files, fn file_name ->
      hd(String.split(hd(tl(String.split(file_name, "/"))),
                      ".u"))
    end)
    Enum.map(module_names, &execute_tests(&1))
    |> List.flatten
    |> Enum.map(&IO.inspect(&1))
  end

  defp execute_tests(module_name) do
    module = String.to_atom(module_name)
    Enum.map(:proplists.get_all_values(:test, apply(module, :module_info, [:attributes])),
             fn test ->
               {test_func, arity} = List.last(test)
               {test_func, apply(module, test_func, [])}
             end)
  end
end