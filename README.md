<img src="https://github.com/i2y/jet/raw/master/jet_logo.png" width="300px"/>

Jet is a dynamically typed, OOP-functional language that runs on the [Erlang](http://www.erlang.org) virtual machine (BEAM).
Its syntax and object model are influenced by [Ruby](https://www.ruby-lang.org) and [Reia](https://github.com/tarcieri/reia).

## Language Features

### Types

```ruby
# Numbers
49        # integer
4.9       # float

# Booleans
true
false

# Atoms
:foo

# Lists
list = [2, 3, 4]
[1, *list]             # => [1, 2, 3, 4]
[head, *rest] = list   # head => 2, rest => [3, 4]

# Tuples
{1, 2, 3}

# Maps
dict = {name: "jet", version: 2}
dict.get(:name, "?")  # => "jet"

# Strings (charlists)
"Hello"

# Binaries
<<1, 2, 3>>
<<"abc">>

# Anonymous functions
add = {|x, y| x + y}
add.(3, 4)  # => 7

multiply = do |x, y|
  x * y
end
```

### Variable Rebinding

```ruby
# x = x + 1 just works — the compiler generates fresh BEAM variables
total = 0
total = total + 10
total = total + 20
total  # => 30
```

### Classes & Immutable State

```ruby
module Geometry
  class Point
    def initialize(x, y)
      @x = x
      @y = y
      self
    end

    def move(dx, dy)
      @x = @x + dx
      @y = @y + dy
      self
    end

    def x()  @x  end
    def y()  @y  end
  end
end

p = Geometry::Point.new(0, 0)
p2 = p.move(3, 4)
# p is unchanged — each mutation returns a new object
```

### Mixins — Composition over Inheritance

```ruby
module MyStack
  class Stack
    include Enumerable

    def initialize()
      @items = []
      self
    end

    def push(item)
      @items = [item, *@items]
      self
    end

    def reduce(acc, func)
      lists::foldl({|item, a| func.(a, item)}, acc, @items)
    end
  end
end

s = MyStack::Stack.new().push(10).push(20).push(30)
s.map {|n| n * 2}                 # => [60, 40, 20]
s.reduce(0) {|acc, n| acc + n}    # => 60
```

### Actors

The `actor` keyword creates a process-backed class (OTP gen_server). `expose` declares its public interface.

```ruby
module Chat
  actor Room
    expose post(user, text), recent(n), count()

    def initialize(name)
      @name = name
      @messages = []
    end

    def post(user, text)
      @messages = [{user, text}, *@messages]
      :ok
    end

    def recent(n)
      lists::sublist(@messages, n)
    end

    def count()
      erlang::length(@messages)
    end

    def on_terminate(reason)
      puts("Room closing: ~p", [reason])
    end
  end
end

room = Chat::Room.spawn("general")
room.post("alice", "Hello!")
room.count()  # => 1

# Async & cast
future = room.async().count()
future.await()        # => 1
room.cast().post("bob", "Fire and forget")

# Timers & raw messages
room ! {:custom, "message"}     # send raw message (handled by on_message)
send_after(1000, room, :ping)   # delayed message

# Monitoring
monitor(room)  # receive {:DOWN, ref, :process, pid, reason} on exit
```

### Effect Declarations (`needs` / `platform`)

```ruby
module Greeter
  needs Console

  def self.greet(name)
    Console::puts("Hello, " ++ name ++ "!")
  end
end

# Provide concrete implementations via platform blocks
platform Production
  provide Console with StandardConsole
end
```

### Pattern Matching

```ruby
match {x, y}
  case {0, 0}
    "origin"
  case {0, _}
    "on Y axis"
  case {x, y} if x == y
    "on diagonal"
  case _
    "somewhere else"
end
```

### Erlang Interop

```ruby
# Call any Erlang/OTP module with :: syntax
node = erlang::node()
timer::sleep(1000)
lists::sort([3, 1, 2])  # => [1, 2, 3]
```

### Higher-Order Functions

```ruby
nums = [5, 3, 8, 1, 9]

nums.map {|n| n * 2}             # => [10, 6, 16, 2, 18]
nums.select {|n| n > 4}          # => [5, 8, 9]
nums.reduce(0) {|acc, n| acc + n}  # => 26

3.times do |i|
  puts("tick ~p", [i])
end
```

## Requirements

- Erlang/OTP >= 26.0
- Gleam >= 1.0

## Installation

```sh
$ git clone https://github.com/i2y/jet.git
$ cd jet
$ gleam build
$ gleam export erlang-shipment && escript build_escript.erl
$ ./jet --help
```

## Usage

### Compiling a single file

```sh
$ ./jet Foo.jet
```

### Compiling and executing

```sh
$ ./jet -r Foo::bar Foo.jet
```

### Building a project

```sh
$ ./jet build src/
```

### Building an escript (standalone executable)

Bundle all `.beam` files into a single executable. Requires Erlang on the target machine.

```sh
$ ./jet escript MyApp src/
$ ./myapp
```

### Building an OTP release

Generate a release directory with `bin/` launcher and `ebin/` beams.

```sh
$ ./jet release MyApp src/
$ ./_release/bin/myapp
```

**Entry point convention:** `jet escript` and `jet release` call `Module::main()`. Define `def self.main()` in your app module.

### Running tests

```sh
$ gleam test
```
