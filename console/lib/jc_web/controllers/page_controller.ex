defmodule JcWeb.PageController do
  use JcWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
