defmodule Jet.Mixfile do
  use Mix.Project

  def project do
    [app: :jet,
     version: "0.0.1",
     elixir: "~> 1.1",
     compilers: Mix.compilers ++ [:jet],
     escript: [main_module: Jet],
     docs: [readme: true, main: "README.md"],
     description: """
     Jet is a simple OOP, dynamically typed, functional language that runs on the Erlang virtual machine (BEAM).
     """,
     deps: deps,
     package: package]
  end

  defp deps do
    # [{:erlport, github: "hdima/erlport"}]
    []
  end

  defp package do
    %{
      licenses: ["MIT"],
      maintainers: ["Yasushi Itoh"],
      links: %{ "GitHub" => "https://github.com/i2y/jet" }
    }
  end
end
