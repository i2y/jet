defmodule JcWeb.McpController do
  @moduledoc """
  Minimal MCP-over-HTTP (JSON-RPC) server exposing ONE tool, `approve` — the permission-prompt
  tool the native `claude` CLI calls (via `--permission-prompt-tool mcp__jetperm__approve`) when a
  tool needs permission. We route it to the owning native-Claude connection process (token -> pid
  via Jc.NativePerm), which raises the Console 🔐 and blocks for the user's Allow/Deny, then we
  return the decision as the MCP tool result claude expects:
    allow -> {"behavior":"allow","updatedInput": <the original input>}
    deny  -> {"behavior":"deny","message": "..."}
  Each native connection points claude at /mcp/perm/<its token>, so the call correlates to the
  right thread with no shared state beyond the registry.
  """
  use JcWeb, :controller

  # one POST = one JSON-RPC message. Requests (with id) get a JSON result; the lone notification
  # (notifications/initialized) gets a 202. Always echo/assign an Mcp-Session-Id.
  def rpc(conn, params) do
    conn = put_session_header(conn)
    token = conn.params["token"]

    case handle(params, token) do
      :empty -> send_resp(conn, 202, "")
      body -> json(conn, body)
    end
  end

  defp handle(%{"method" => "initialize", "id" => id}, _token) do
    result(id, %{
      "protocolVersion" => "2024-11-05",
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "jetperm", "version" => "0.1.0"}
    })
  end

  defp handle(%{"method" => "notifications/" <> _}, _token), do: :empty

  defp handle(%{"method" => "tools/list", "id" => id}, _token) do
    result(id, %{
      "tools" => [
        %{
          "name" => "approve",
          "description" => "Permission prompt: approve or deny a tool use, routed to the Jet Console UI.",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{
              "tool_name" => %{"type" => "string"},
              "input" => %{"type" => "object"},
              "tool_use_id" => %{"type" => "string"}
            }
          }
        }
      ]
    })
  end

  defp handle(%{"method" => "tools/call", "id" => id, "params" => p}, token) do
    args = p["arguments"] || %{}
    tool_name = args["tool_name"] || "tool"
    input = args["input"] || %{}

    payload =
      case ask(token, tool_name, input) do
        :allow -> %{"behavior" => "allow", "updatedInput" => input}
        _ -> %{"behavior" => "deny", "message" => "Denied by the user in Jet Console."}
      end

    # the permission result is returned as JSON text in the tool's content (the SDK parses it back)
    result(id, %{"content" => [%{"type" => "text", "text" => Jason.encode!(payload)}]})
  end

  defp handle(%{"id" => id}, _token), do: error(id, -32601, "method not found")
  defp handle(_other, _token), do: :empty

  # hand the request to the owning connection process and wait for the user's decision.
  defp ask(token, tool_name, input) do
    case token && Jc.NativePerm.lookup(token) do
      {:ok, pid} ->
        send(pid, {:native_permission, %{title: title_for(tool_name, input), kind: tool_name}, self()})

        receive do
          {:native_permission_decision, d} -> d
        after
          300_000 -> :deny
        end

      _ ->
        :deny
    end
  end

  defp title_for(tool_name, input) when is_map(input) do
    hint = input["command"] || input["file_path"] || input["path"] || input["url"] || input["pattern"] || ""
    if hint == "" or not is_binary(hint), do: tool_name, else: "#{tool_name}: #{hint}"
  end

  defp title_for(tool_name, _), do: tool_name

  defp result(id, r), do: %{"jsonrpc" => "2.0", "id" => id, "result" => r}
  defp error(id, code, msg), do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => msg}}

  defp put_session_header(conn) do
    sid =
      case get_req_header(conn, "mcp-session-id") do
        [s | _] -> s
        _ -> "jetperm-session"
      end

    put_resp_header(conn, "mcp-session-id", sid)
  end
end
