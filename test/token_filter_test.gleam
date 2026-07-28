import gleeunit
import gleeunit/should
import jet/lexer
import jet/token
import jet/token_filter

pub fn main() {
  gleeunit.main()
}

/// modules named by a qualified call, after the filter has run
fn qualified(src: String) -> List(String) {
  let assert Ok(tokens) = lexer.lex(src)
  collect(token_filter.filter(tokens, "m"), [])
}

fn collect(
  tokens: List(#(token.Token, token.Position)),
  acc: List(String),
) -> List(String) {
  case tokens {
    [] -> acc
    [#(token.Name(n), _), #(token.ColonColon, _), ..rest] ->
      collect(rest, [n, ..acc])
    [_, ..rest] -> collect(rest, acc)
  }
}

pub fn alias_rewrites_qualified_call_test() {
  qualified("alias jet_backend as B\nB::to_bin(x)")
  |> should.equal(["jet_backend"])
}

pub fn alias_works_before_its_declaration_test() {
  // collected across the whole file first, so order does not matter
  qualified("B::to_bin(x)\nalias jet_backend as B")
  |> should.equal(["jet_backend"])
}

pub fn alias_leaves_other_modules_alone_test() {
  qualified("alias jet_backend as B\nlists::reverse(x)")
  |> should.equal(["lists"])
}

pub fn alias_does_not_touch_a_variable_of_the_same_name_test() {
  // only `Name` immediately followed by `::` is rewritten
  let assert Ok(tokens) = lexer.lex("alias jet_backend as B\nB = 1\nB + 2")
  let filtered = token_filter.filter(tokens, "m")
  should.be_true(
    list_any(filtered, fn(t) {
      case t {
        #(token.Name("B"), _) -> True
        _ -> False
      }
    }),
  )
}

pub fn alias_declaration_is_removed_test() {
  let assert Ok(tokens) = lexer.lex("alias jet_backend as B\nB::f(x)")
  let filtered = token_filter.filter(tokens, "m")
  should.be_false(
    list_any(filtered, fn(t) {
      case t {
        #(token.Alias, _) -> True
        _ -> False
      }
    }),
  )
}

pub fn import_and_require_are_ordinary_names_test() {
  // both were reserved for ten years with no grammar rule behind them
  let assert Ok(tokens) = lexer.lex("import")
  let assert [#(token.Name("import"), _)] = tokens
  let assert Ok(tokens2) = lexer.lex("require")
  let assert [#(token.Name("require"), _)] = tokens2
}

fn list_any(
  l: List(#(token.Token, token.Position)),
  f: fn(#(token.Token, token.Position)) -> Bool,
) -> Bool {
  case l {
    [] -> False
    [x, ..rest] ->
      case f(x) {
        True -> True
        False -> list_any(rest, f)
      }
  }
}
