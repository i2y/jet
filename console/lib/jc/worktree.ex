defmodule Jc.Worktree do
  @moduledoc """
  Opt-in git worktree isolation for a thread. An isolated thread works on its own branch in its
  own worktree (under ~/.jet_console/worktrees), so an editing agent's changes never touch the
  project's working tree until you **Merge** — or vanish when you **Discard**. Lets several
  threads edit the same repo concurrently without clobbering each other.
  """

  @doc "is `dir` inside a git work tree?"
  def repo?(dir),
    do: is_binary(dir) and match?({_, 0}, sys(dir, ["rev-parse", "--is-inside-work-tree"]))

  @doc "create a worktree + branch for thread `id` off `dir`'s repo -> {:ok, %{path, branch, base}} | {:error, msg}"
  def create(dir, id) do
    if repo?(dir) do
      base = base_branch(dir)
      branch = "jet-console/t#{id}"
      path = Path.join(root(), "#{Path.basename(dir)}-t#{id}")
      File.mkdir_p!(root())
      # clear any stale worktree/branch from a previous run so re-isolating works
      sys(dir, ["worktree", "prune"])
      sys(dir, ["worktree", "remove", "--force", path])
      sys(dir, ["branch", "-D", branch])

      case sys(dir, ["worktree", "add", path, "-b", branch]) do
        {_, 0} -> {:ok, %{path: path, branch: branch, base: base}}
        {err, _} -> {:error, String.trim(err)}
      end
    else
      {:error, "not a git repository: #{dir}"}
    end
  end

  @doc "commit the worktree's changes on its branch, then merge that branch into the base. :ok | {:error, msg}"
  def merge(dir, %{path: path, branch: branch}) do
    sys(path, ["add", "-A"])
    sys(path, ["commit", "-m", "jet-console: agent changes (#{branch})"])

    case sys(dir, ["merge", "--no-edit", branch]) do
      {_, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  end

  @doc "remove the worktree and delete its branch (drops the agent's changes)."
  def discard(dir, %{path: path, branch: branch}) do
    sys(dir, ["worktree", "remove", "--force", path])
    sys(dir, ["branch", "-D", branch])
    :ok
  end

  def discard(_dir, _), do: :ok

  defp base_branch(dir) do
    case sys(dir, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp root, do: Path.join(System.user_home!(), ".jet_console/worktrees")

  defp sys(dir, args) do
    System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
  rescue
    _ -> {"git not found", 1}
  end
end
