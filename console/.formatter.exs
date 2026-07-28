[
  import_deps: [:phoenix],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs:
    (Path.wildcard("*.{heex,ex,exs}") ++
       Path.wildcard("{config,lib,test}/**/*.{heex,ex,exs}"))
    # chat_live.ex is written in a deliberately dense style -- long single-line assigns and
    # tight HEEx. The formatter (with the HTML plugin) reflows it 2018 -> 3180 lines, so it
    # is excluded rather than re-expanded on every `mix precommit`.
    |> Enum.reject(&(&1 == "lib/jc_web/live/chat_live.ex"))
]
