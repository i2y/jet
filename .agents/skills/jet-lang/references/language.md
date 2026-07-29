# The rest of the language

Read this when you need more than the traps in `SKILL.md` — classes, actors, matching, error
handling, and reaching into Erlang/OTP. For anything involving `agent`, read `agents.md`.

## One object model

`class`, `actor` and `agent` are the same object model at three levels of aliveness, and
`x.method()` calls all three. Under the hood a class becomes a map of functions and dispatch goes
through `jet_runtime::call_method/3`, which is also why method calls work on primitives
(`4.to_s()`, `[1,2].map(...)`).

```jet
class Point
  def initialize(x, y)
    @x = x
    @y = y
  end
  def dist()
    math::sqrt(@x * @x + @y * @y)
  end
end

p = Point.new(3, 4)
p.dist()
```

`@attr` reads and writes instance state. `initialize` receives a fresh empty object and, Ruby-like,
must end up returning `self` — an empty body does the right thing.

## Actors

An `actor` is a supervised gen_server. It gets `spawn()` instead of `new()`, and **it needs an
explicit `def initialize()`** (see SKILL.md).

```jet
actor Counter
  def initialize()
    @total = 0
  end
  def add(n)
    @total = @total + n
    @total
  end
  def on_message(msg)      # a cast / bare message
    :ok
  end
  def on_terminate(reason)
    :ok
  end
end

c = Counter.spawn()
c.add(5)                   # a call — returns 5
```

State lives in the gen_server, threaded back automatically; you write `@total = …` and it persists
across calls. `on_*` is the callback convention (`on_message`, `on_terminate`, `on_approval`).

## Pattern matching

```jet
match value
  case {:ok, v}
    v
  case {:error, reason} if erlang::is_atom(reason)   # `if`, never `when`
    reason
  case [h, *rest]                # NOT [h | rest]
    h
  case {name: n}                 # map pattern
    n
  case _
    :fallthrough
end
```

`match` over an `enum(...)` schema is checked at compile time: omitting a value, or naming one the
enum lacks, is a warning that names it.

Rebinding is allowed — `x = x + 1` is fine; the compiler renames to unique BEAM variables for you.

## Errors

`try` / `catch` / `finally` exist, and the caught value is an exception map:

```jet
try
  risky()
catch e
  io::format("~p: ~p~n", [e.get(:class), e.get(:reason)])
end
```

Prefer `{:ok, _}` / `{:error, _}` plus `match` for failures you expect; keep `try` for the ones you
don't. `erlang::error({:my_tag, detail})` raises a typed error — much better than returning an empty
string that masquerades as a real answer downstream.

## Functions, lambdas, pipes

```jet
def self.double(x)          # a module function -> Module::double(x)
  x * 2
end

f = {|x| x * 2}             # a lambda
f.(21)
lists::map({|x| x * 2}, [1, 2, 3])

[1, 2, 3] |> lists::sum()   # `|` alone is the pipe operator — which is why [h|t] is broken
```

A lambda's parameters bind tightly, so `{|x| ...}` is unambiguous. Blocks are also written
`do |x| … end` for `tool` bodies and `.stream`.

## Calling Erlang and OTP

`module::function(args)` calls Erlang directly: `lists::`, `maps::`, `binary::`, `erlang::`,
`io::`, `io_lib::`, `file::`, `filename::`, `os::`, `re::`, `string::`, `ets::`, `timer::`,
`gen_server::`. Standard OTP semantics apply, which means standard OTP data types — mind the
char-list-vs-binary distinction in SKILL.md.

When a name is a Jet keyword the qualified call cannot be written (`erlang::raise`,
`binary::match`); go through `erlang::apply(:module, :function, [args])`.

`alias X as Y` renames a module prefix for the whole file — a pure token rewrite, so declaration
order is irrelevant, and only a name immediately followed by `::` is affected:

```jet
alias jet_mcp_client as mcp
mcp::connect(cmd)          # compiles as jet_mcp_client::connect(cmd)
```

There is **no `import` or `require`**. BEAM module names are global and resolved at run time, so a
qualified call is already complete on its own.

## Building

```sh
./jet File.jet                     # -> File.beam beside it
./jet -r Module::func File.jet      # compile and run
./jet build src/                    # a whole directory
./jet escript MyApp src/            # a single executable (needs Erlang on the target)
./jet release MyApp src/            # an OTP release directory
```

The compiler itself is written in Gleam, with Erlang FFI. That matters in one practical way: a new
`src/*_ffi.erl` is invisible to `./jet` until you rebuild the compiler —
`gleam build && gleam export erlang-shipment && escript build_escript.erl`. Editing a `.jet` file
needs no such step.

The standard library in `src/` is itself written in Jet. It is the best available reference for how
to write idiomatic Jet, and it is right there in the checkout.
