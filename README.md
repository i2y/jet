# Uiro

Uiro is a simple OOP, dynamically typed, functional language that runs on the [Erlang](http://www.erlang.org) virtual machine (BEAM).
Uiro's syntax is [Ruby](https://www.ruby-lang.org)-like syntax. Uiro also got an influence from [Python](https://www.python.org) and [Mochi](https://github.com/i2y/mochi).

Its interpreter is written in Elixir. The interpreter translates a program written in Uiro to Erlang's AST / bytecode.

## Language features
### Module definition
```ruby
module Enumerable
  def select(func)
    self.reduce([]) {|item, acc|
      if func.(item)
        acc ++ [item]
      else
        acc
      end
    }
  end
  
  def filter(func)
    self.reduce([]) {|item, acc|
      if func.(item)
        acc ++ [item]
      else
        acc
      end
    }
  end
  
  def reject(func)
    self.reduce([]) {|item, acc|
      if func.(item)
        acc
      else
        acc ++ [item]
      end
    }
  end
  
  def map(func)
    self.reduce([]) {|item, acc|
      acc ++ [func.(item)]
    }
  end
  
  def collect(func)
    self.reduce([]) {|item, acc|
      acc ++ [func.(item)]
    }
  end
  
  def min(func)
    self.reduce(:infinity) {|item, acc|
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
    self.reduce(:infinity) {|item, acc|
      if acc <= item
        acc
      else
        item
      end
    }
  end
  
  def unique()
    self.reduce([]) {|item, acc|
      if acc.index_of(item)
        acc
      else
        acc ++ [item]
      end
    }
  end
  
  def each(func)
    self.reduce([]) {|item, acc|
      func.(item)
    }
  end
end
```


### Class definition
```ruby
class Car
  def initialize()
    {name: "foo",
     speed: 100}
  end
  
  def self.test()
    1000
  end
  
  def print()
    "Elixir.IO"::inspect(@name)
    "Elixir.IO"::inspect(@speed)
  end
end
```

### Mixing in Modules
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
# => [1, 2, 3, 4, 5, 6]
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
