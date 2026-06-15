import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/jc start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :jc, JcWeb.Endpoint, server: true
end

config :jc, JcWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  # Point the Jet runtime at the bundled copy inside the release (priv/jet), unless overridden.
  System.put_env("JET_ROOT", System.get_env("JET_ROOT") || Path.join(:code.priv_dir(:jc), "jet"))

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :jc, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Bind to loopback (127.0.0.1) by default — a personal Console reached over localhost or an SSH
  # tunnel, and not exposed on the LAN. A loopback bind also means a same-machine `ssh -L
  # 4000:localhost:4000` cleanly no-ops (its bind conflicts and falls through) instead of hijacking
  # the port. Set JET_CONSOLE_BIND_ALL=1 to bind all interfaces (IPv6 + IPv4) for LAN access.
  bind_ip =
    if System.get_env("JET_CONSOLE_BIND_ALL") in ["1", "true"],
      do: {0, 0, 0, 0, 0, 0, 0, 0},
      else: {127, 0, 0, 1}

  config :jc, JcWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: bind_ip],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :jc, JcWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :jc, JcWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
