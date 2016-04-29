defmodule Uiro.Mixfile do
  use Mix.Project

  def project do
    [app: :uiro,
     version: "0.0.1",
     elixir: "~> 1.1",
     compilers: Mix.compilers ++ [:uiro],
     escript: [main_module: Uiro],
     docs: [readme: true, main: "README.md"],
     description: """
     Uiro is a simple OOP, dynamically typed, functional language that runs on the Erlang virtual machine (BEAM).
     Uiro's sytnax is Ruby-like syntax. Uiro also got an influence from Python and Mochi.
     """,
     deps: deps]
  end

  defp deps do
    []
  end

  defp package do
    %{
      licenses: ["MIT"],
      maintainers: ["Yasushi Itoh"],
      links: %{ "GitHub" => "https://github.com/i2y/uiro" }
    }
  end
end
