import gleeunit
import gleeunit/should
import jet/ast
import jet/lexer
import jet/parser
import jet/token_filter

pub fn main() {
  gleeunit.main()
}

fn parse_source(source: String) -> Result(ast.Module, Nil) {
  case lexer.lex(source) {
    Ok(tokens) -> {
      let module_name = "test_module"
      let filtered = token_filter.filter(tokens, module_name)
      case parser.parse(filtered, module_name) {
        Ok(module) -> Ok(module)
        Error(_) -> Error(Nil)
      }
    }
    Error(_) -> Error(Nil)
  }
}

pub fn parse_empty_module_test() {
  let assert Ok(module) =
    parse_source(
      "module Foo
end",
    )
  should.equal(module.name, "Foo")
}

pub fn parse_module_with_method_test() {
  let assert Ok(module) =
    parse_source(
      "module Bar
  def self.hello()
    42
  end
end",
    )
  should.equal(module.name, "Bar")
}

pub fn parse_platform_def_test() {
  let assert Ok(module) =
    parse_source(
      "module PlatTest
  platform Production
    provide IO with StandardIO
    provide DB with PostgresDB
  end
end",
    )
  should.equal(module.name, "PlatTest")
  // Should have ModuleDecl + PlatformDef
  let assert [_, ast.PlatformDef(name, _, providers)] = module.body
  should.equal(name, "Production")
  let assert [
    ast.ProvideClause("IO", "StandardIO", _),
    ast.ProvideClause("DB", "PostgresDB", _),
  ] = providers
}

pub fn parse_using_clause_test() {
  let assert Ok(module) =
    parse_source(
      "module UsingTest
  def self.my_test() using MockIO for IO
    42
  end
end",
    )
  should.equal(module.name, "UsingTest")
  let assert [_, ast.UsingFunc(func, overrides)] = module.body
  let assert ast.FuncDef("my_test", _, _, _, _, _) = func
  let assert [ast.UsingOverride("MockIO", "IO", _)] = overrides
}

pub fn parse_using_multiple_overrides_test() {
  let assert Ok(module) =
    parse_source(
      "module UsingTest2
  def self.foo() using MockIO for IO, MockDB for DB
    42
  end
end",
    )
  let assert [_, ast.UsingFunc(_, overrides)] = module.body
  let assert [
    ast.UsingOverride("MockIO", "IO", _),
    ast.UsingOverride("MockDB", "DB", _),
  ] = overrides
}

pub fn parse_expose_in_class_test() {
  let assert Ok(module) =
    parse_source(
      "class Counter
  meta Actor
  expose increment(), get_count()
  def initialize()
    42
  end
end",
    )
  let assert [_, ast.ClassDef("Counter", _, methods, _)] = module.body
  let assert [
    ast.Attribute("_Counter_meta", _, _),
    ast.ExposeDecl(exposed, _),
    ast.FuncDef("_Counter_instance_method_initialize", _, _, _, _, _),
  ] = methods
  let assert [
    ast.ExposedMethod("increment", 0, _),
    ast.ExposedMethod("get_count", 0, _),
  ] = exposed
}

pub fn parse_peers_in_class_test() {
  let assert Ok(module) =
    parse_source(
      "class Counter
  meta Actor
  peers logger: Logger, store: Store
  def initialize()
    42
  end
end",
    )
  let assert [_, ast.ClassDef("Counter", _, methods, _)] = module.body
  let assert [
    ast.Attribute("_Counter_meta", _, _),
    ast.PeersDecl(peers, _),
    ast.FuncDef("_Counter_instance_method_initialize", _, _, _, _, _),
  ] = methods
  let assert [
    ast.PeerDef("logger", "Logger", _),
    ast.PeerDef("store", "Store", _),
  ] = peers
}

pub fn parse_actor_keyword_test() {
  let assert Ok(module) =
    parse_source(
      "actor Counter
  expose increment(), get_count()
  def initialize()
    42
  end
end",
    )
  let assert [_, ast.ClassDef("Counter", _, methods, True)] = module.body
  let assert [
    ast.ExposeDecl(exposed, _),
    ast.FuncDef("_Counter_instance_method_initialize", _, _, _, _, _),
  ] = methods
  let assert [
    ast.ExposedMethod("increment", 0, _),
    ast.ExposedMethod("get_count", 0, _),
  ] = exposed
}

pub fn parse_expose_with_args_test() {
  let assert Ok(module) =
    parse_source(
      "class MyActor
  expose send_message(to, body), stop()
end",
    )
  let assert [_, ast.ClassDef("MyActor", _, methods, _)] = module.body
  let assert [ast.ExposeDecl(exposed, _)] = methods
  let assert [
    ast.ExposedMethod("send_message", 2, _),
    ast.ExposedMethod("stop", 0, _),
  ] = exposed
}
