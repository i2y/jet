<img src="https://github.com/i2y/jet/raw/master/jet_logo.png" style="max-width: 300px"/>
> "I thought of objects being like biological cells and/or individual
> computers on a network, only able to communicate with messages"
> _--Alan Kay, creator of Smalltalk, on the meaning of "object oriented programming"_


Jet is a simple OOP, dynamically typed, functional language that runs on the [Erlang](http://www.erlang.org) virtual machine (BEAM).
Jet's syntax is [Ruby](https://www.ruby-lang.org)-like syntax.

Jet was inspired by [Reia](https://github.com/tarcieri/reia) and [Celluloid](https://github.com/celluloid/celluloid).
Jet has actor library like [Celluloid](https://github.com/celluloid/celluloid) that supports synchronous message passing and asynchronous message passing. For the examples, please see [SampleActor.jet](https://github.com/i2y/jet/blob/master/src/SampleActor.jet) and [test_basic.jet](https://github.com/i2y/jet/blob/master/test/test_basic.jet).

Jet also has a stream processing library like [Streem](https://github.com/matz/streem). For the examples, please see [test_basic.jet](https://github.com/i2y/jet/blob/master/test/test_basic.jet).

## Language features
### Builtin Types
```ruby
### Numbers

49  # integer
4.9 # float

### Booleans

true
false

### Atoms

:foo

### Lists

list = [2, 3, 4]
list2 = [1, *list] # => [1, 2, 3, 4]
[1, 2, 3, *rest] = list2
rest # => [4]

list.append(5) # => [2, 3, 4, 5]
list # => [2, 3, 4]


list.select {|item| item > 2}
    .map {|item| item * 2} # => [6, 8]
list # => [2, 3, 4]

# list comprehensions
[n * 2 for n in list] # => [4, 6, 8]

### Tuples

tuple = {1, 2, 3}
tuple.select {|item| item > 1}
     .map {|item| item * 2} # => [4, 6]

tuple.to_list # => [1, 2, 3]


### Maps

dict = {foo: 1, bar: 2}
dict2 = dict.put(:baz, 3) # => {foo: 1, bar: 2, baz: 3}
dict # => {foo: 1, bar: 2}
dict.get(:baz, 100) # => 100

### Strings (Lists)

"Abc"


### Anonymous functions (Blocks)

add = {|x, y| x + y}
add(40, 9) # => 49

multiply = do |x, y|
  x * y
end

multiply(7, 7) # => 49


### Binaries

<<1, 2, 3>>
<<"abc">>
<<1 , 2, x>> = <<1, 2, 3>>
x # => 3

```

### Class definition
Car.jet
```ruby
class Car
  # On jet, state of an instance is immutable.
  # The initialize method returns initial state of an instance.
  def initialize()
    {name: "foo",
     speed: 100}
  end

  def display()
    @name.display()
    @speed.display()
  end
end
```

### Module definition
Enumerable.jet
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
SampleList.jet
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

### Module attributes
SampleList.mj:
```ruby
class SampleList
  include Enumerable
  @@author("i2y", "others") # a module attribute

  def initialize(items)
    {items: items}
  end

  obsolete # a module attribute and an annotation
  def reduce(acc, func)
    lists::foldl(func, acc, @items)
  end

  obsolete("since version 12")
  def append(item)
    @items.append(item)
  end
end

# # usage:
# list = new SampleList([1, 2, 3])
# list.class_attr_values(:author)
# # => [["i2y", "others"]]
# list.class_attr_values(:obsolete)
# # => [[(:reduce, 3)], ["since version 12", (:append, 2)]]
```

### Trailing closures (Trailing blocks)
```ruby
sample_list = new SampleList([1, 2, 3])
sample_list.select {|item| item > 1}
           .map {|item| item * 2}
           # => [4, 6]
```

### Other supported features
- Tail recursion optimization
- Pattern matching

### Not supported features
- Class inheritance
- Macro definition

## Requirements
- Erlang/OTP >= 18.0
- Elixir >= 1.1

## Installation
```sh
$ git clone https://github.com/i2y/jet.git
$ cd jet
$ mix archive.build
$ mix archive.install
$ mix escript.build
$ cp jet <any path>
```

## Usage
### Command
Compiling:
```sh
$ ls
Foo.jet
$ jet Foo.jet
$ ls
Foo.beam Foo.jet
```

Compiling and Executing:
```sh
$ cat Foo.jet
module Foo
  def self.bar()
    123.display()
  end
end
$ jet -r Foo::bar Foo.jet
123
```

### Mix
mix.exs file example:
```elixir
defmodule MyApp.Mixfile do
  use Mix.Project

  def project do
    [app: :my_app,
     version: "1.0.0",
     compilers: [:jet|Mix.compilers],
     deps: [{:jet, git: "https://github.com/i2y/jet.git"}]]
  end
end
```
".jet" files in source directory(src) is automatically compiled by mix command.
