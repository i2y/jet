# Uiro

Uiro is a simple OOP, dynamically typed, functional language that runs on the [Erlang](http://www.erlang.org) virtual machine (BEAM).
Uiro's syntax is [Ruby](https://www.ruby-lang.org)-like syntax.

Uiro has actor library like [Celluloid](https://github.com/celluloid/celluloid) that supports synchronous message passing and asynchronous message passing. For the examples, please see [SampleActor.u](https://github.com/i2y/uiro/blob/master/src/SampleActor.u) and [test_basic.u](https://github.com/i2y/uiro/blob/master/test/test_basic.u).
Uiro also has a stream processing library like [streem](). For the examples, please see [test_basic.u](https://github.com/i2y/uiro/blob/master/test/test_basic.u).

## Language features
### Class definition
Car.u
```ruby
class Car
  def initialize()
    {name: "foo",
     speed: 100}
  end

  def inspect()
    "Elixir.IO"::inspect(@name)
    "Elixir.IO"::inspect(@speed)
  end
end
```

### Module definition
Enumerable.u
```ruby
module Enumerable
  def select(func)
    reduce([]) {|item, acc|
      if func.(item)
        acc ++ [item]
      else
        acc
      end
    }
  end

  def filter(func)
    reduce([]) {|item, acc|
      if func.(item)
        acc ++ [item]
      else
        acc
      end
    }
  end

  def reject(func)
    reduce([]) {|item, acc|
      if func.(item)
        acc
      else
        acc ++ [item]
      end
    }
  end

  def map(func)
    reduce([]) {|item, acc|
      acc ++ [func.(item)]
    }
  end

  def collect(func)
    reduce([]) {|item, acc|
      acc ++ [func.(item)]
    }
  end

  def min(func)
    reduce(:infinity) {|item, acc|
      match func.(acc, item)
        case -1
          0
        case 0
          0
        case 1
          item
      end
    }
  end

  def min()
    reduce(:infinity) {|item, acc|
      if acc <= item
        acc
      else
        item
      end
    }
  end

  def unique()
    reduce([]) {|item, acc|
      if acc.index_of(item)
        acc
      else
        acc ++ [item]
      end
    }
  end

  def each(func)
    reduce([]) {|item, acc|
      func.(item)
    }
  end
end
```

### Mixing in Modules
SampleList.u
```ruby
class SampleList
  include Enumerable

  def initialize(items)
    {items: items}
  end

  def reduce(acc, func)
    lists::foldl(func, acc, @items)
  end
end
```

### Trailing closures (Trailing blocks)
```ruby
sample_list = new SampleList([1, 2, 3])
sample_list.select {|item| item > 1}
           .map {|item| item * 2}
           # => [4, 6]
```

### Pipe operator
```ruby
[1, 2, 3] |> lists::append([4, 5, 6])
          |> lists::append([7, 8, 9])
# => [1, 2, 3, 4, 5, 6, 7, 8, 9]
```

### Other supported features
- Tail recursion optimization
- Pattern matching
- List comprehension

### Not supported features
- Class inheritance
- Macro definition

## Installation
TODO

## Usage
Mixfile example
```elixir
defmodule Uiro.Mixfile do
  use Mix.Project

  def project do
    [app: :uiro,
     version: "0.0.1",
     elixir: "~> 1.1",
     compilers: [:uiro] ++ Mix.compilers,
     escript: [main_module: Uiro],
     docs: [readme: true, main: "README.md"]]
  end
end
```
".u" files in source directory(src) is automatically compiled by mix command.
