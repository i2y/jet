defmodule JcWeb.Router do
  use JcWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {JcWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", JcWeb do
    pipe_through :browser

    live "/", ChatLive
  end

  # native-Claude permission bridge: the claude CLI calls this MCP endpoint (--permission-prompt-tool)
  # when a tool needs approval; McpController routes it to the Console 🔐. No :accepts plug — claude
  # sends Accept: application/json, text/event-stream and we always answer JSON.
  scope "/mcp", JcWeb do
    post "/perm/:token", McpController, :rpc
  end

  # Other scopes may use custom stacks.
  # scope "/api", JcWeb do
  #   pipe_through :api
  # end
end
