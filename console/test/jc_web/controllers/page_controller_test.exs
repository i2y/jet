defmodule JcWeb.PageControllerTest do
  use JcWeb.ConnCase

  # "/" is `live "/", ChatLive` (see router.ex) -- not the generated landing page, whose
  # stock copy this asserted until the root route was pointed at the Console.
  test "GET / serves the Console", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Jet Console"
  end
end
