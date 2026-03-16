# Jet 2.0 Roadmap

Jet is a dynamically-typed, OOP-functional language with Ruby-like syntax that compiles to BEAM bytecode.

## Design Principles

- **BEAM-native**: Compile to standard BEAM bytecode; interop with Erlang/Elixir seamlessly
- **Effect-aware**: Separate pure computations from side effects via `needs` declarations
- **Actor-first**: First-class support for OTP patterns through `meta Actor` and `expose`
- **Simple OOP**: Immutable instance state, mixin-based composition, no inheritance

## Phase 0: Foundation (Gleam Rewrite)

Rewrite the compiler from Elixir/leex/yecc to Gleam. Full backward compatibility with all existing `.jet` files.

- Hand-written lexer (replaces leex)
- Pratt parser (replaces yecc LALR grammar)
- BEAM codegen via erl_syntax FFI (replaces Elixir compiler module)
- CLI: `jet compile`, `jet run`, `jet test`
- Fix known bugs: `floordiv` typo, `**` operator codegen

## Phase 1: `needs` + Variable Rebinding

### `needs` declarations
Declare effects a function requires. Pure functions have no `needs`.

```ruby
needs IO
def greet(name)
  IO.puts("Hello, " ++ name)
end
```

### Variable rebinding
Allow `x = x + 1` style rebinding (compiles to fresh BEAM variables).

## Phase 2: `platform` + Testing

### `platform` blocks
Define effect boundaries that provide concrete implementations.

```ruby
platform Production
  provide IO with StandardIO
  provide DB with PostgresDB
end
```

### `using` for tests
Override effect providers in test contexts.

```ruby
test
def self.test_greet() using MockIO for IO
  greet("world")
  MockIO.assert_printed("Hello, world")
end
```

## Phase 3: Agents (`expose`, `peers`)

### `expose` declarations
Define the public message interface of an Actor.

```ruby
class Counter
  meta Actor
  expose increment(), get_count()

  def initialize()
    {count: 0}
  end

  def increment()
    update_state(:count, @count + 1)
  end

  def get_count()
    @count
  end
end
```

### `peers` for actor composition
Declare named dependencies between actors.

## Phase 4: External Integration

- **ConnectRPC**: Generate RPC service stubs from `expose` declarations
- **MCP**: Model Context Protocol server/client support
- **A2A**: Agent-to-Agent protocol for multi-agent systems

## Grammar Changes Summary

| Phase | New Keywords | Syntax Changes |
|-------|-------------|----------------|
| 0 | (none) | (backward compatible) |
| 1 | `needs` | Variable rebinding allowed |
| 2 | `platform`, `provide`, `using` | Test DSL extensions |
| 3 | `expose`, `peers` | Actor interface declarations |
| 4 | (none) | Attribute-based annotations |

## Migration Guide (Jet 1.0 to 2.0)

### Build system
- **Before**: `mix deps.get && mix compile && mix escript.build`
- **After**: `gleam build && gleam export erlang-shipment && escript build_escript.erl` (produces `jet` CLI)

### Distribution (new in 2.0)
```sh
jet build src/              # compile all .jet files in a directory
jet escript MyApp src/      # bundle into a standalone escript
jet release MyApp src/      # generate an OTP release directory
```

### Compilation
- **Before**: `jet Foo.jet` or `jet -r Foo::bar Foo.jet`
- **After**: Same commands (backward compatible)

### Source files
All existing `.jet` files compile without changes under Phase 0.

### Standard library
`jet_runtime.jet`, `Kernel.jet`, `Enumerable.jet`, and all type wrapper modules remain unchanged.
