import gleam/dict.{type Dict}
import gleam/list
import jet/token.{type Position, type Token}

/// Filter tokens: apply `alias` renames, replace __name__ with the module name
/// atom, and remove newlines before infix operators and after commas.
pub fn filter(
  tokens: List(#(Token, Position)),
  module_name: String,
) -> List(#(Token, Position)) {
  let #(tokens, aliases) = take_aliases(tokens, [], dict.new())
  tokens
  |> list.map(fn(t) {
    case t {
      #(token.Name("__name__"), pos) -> #(token.Atom(module_name), pos)
      other -> other
    }
  })
  |> apply_aliases(aliases)
  |> remove_extraneous_newlines()
}

/// `alias jet_backend as B` -> every later `B::f(…)` reads `jet_backend::f(…)`.
///
/// Deliberately a pure token rename, not a scope: the call site stays QUALIFIED,
/// so `B::` is still visibly a remote call and one line at the top of the file
/// says what it is. That is the part of `import` worth having. The other part --
/// pulling names in unqualified, so a reader can't tell local from remote -- is
/// what Erlang's own `-import` is discouraged for, and is not offered here.
///
/// Aliases are collected across the whole file first, so declaration order does
/// not matter; only `Name` immediately followed by `::` is rewritten, which
/// leaves a variable of the same name alone.
fn take_aliases(
  tokens: List(#(Token, Position)),
  acc: List(#(Token, Position)),
  aliases: Dict(String, String),
) -> #(List(#(Token, Position)), Dict(String, String)) {
  case tokens {
    [] -> #(list.reverse(acc), aliases)
    [
      #(token.Alias, _),
      #(token.Name(target), _),
      #(token.As, _),
      #(token.Name(short), _),
      ..rest
    ] -> take_aliases(rest, acc, dict.insert(aliases, short, target))
    [t, ..rest] -> take_aliases(rest, [t, ..acc], aliases)
  }
}

fn apply_aliases(
  tokens: List(#(Token, Position)),
  aliases: Dict(String, String),
) -> List(#(Token, Position)) {
  case dict.is_empty(aliases) {
    True -> tokens
    False -> rename(tokens, aliases)
  }
}

fn rename(
  tokens: List(#(Token, Position)),
  aliases: Dict(String, String),
) -> List(#(Token, Position)) {
  case tokens {
    [] -> []
    [#(token.Name(n), pos), #(token.ColonColon, p2), ..rest] -> {
      let head = case dict.get(aliases, n) {
        Ok(target) -> #(token.Name(target), pos)
        Error(_) -> #(token.Name(n), pos)
      }
      [head, #(token.ColonColon, p2), ..rename(rest, aliases)]
    }
    [t, ..rest] -> [t, ..rename(rest, aliases)]
  }
}

fn remove_extraneous_newlines(
  tokens: List(#(Token, Position)),
) -> List(#(Token, Position)) {
  do_filter(tokens, [])
  |> list.reverse()
}

fn do_filter(
  tokens: List(#(Token, Position)),
  acc: List(#(Token, Position)),
) -> List(#(Token, Position)) {
  case tokens {
    [] -> acc
    [#(t, _pos) as tok, ..rest] ->
      case is_infix_op(t) {
        True -> {
          let cleaned_acc = drop_trailing_newlines(acc)
          do_filter(rest, [tok, ..cleaned_acc])
        }
        False ->
          case t {
            token.Newline ->
              case acc {
                [#(prev_tok, _), ..] ->
                  case is_comma(prev_tok) || is_infix_op(prev_tok) {
                    True -> do_filter(rest, acc)
                    False -> do_filter(rest, [tok, ..acc])
                  }
                [] -> do_filter(rest, [tok, ..acc])
              }
            _ -> do_filter(rest, [tok, ..acc])
          }
      }
  }
}

fn drop_trailing_newlines(
  acc: List(#(Token, Position)),
) -> List(#(Token, Position)) {
  case acc {
    [#(token.Newline, _), ..rest] -> drop_trailing_newlines(rest)
    _ -> acc
  }
}

fn is_comma(t: Token) -> Bool {
  case t {
    token.Comma -> True
    _ -> False
  }
}

fn is_infix_op(t: Token) -> Bool {
  case t {
    token.PlusPlus
    | token.Plus
    | token.Minus
    | token.Star
    | token.Slash
    | token.LtEq
    | token.GtEq
    | token.EqEq
    | token.BangEq
    | token.Lt
    | token.Gt
    | token.And
    | token.Or
    | token.Is
    | token.Not
    | token.Bang
    | token.Equals
    | token.Pipe
    | token.Pipeline
    | token.LastPipeline
    | token.For
    | token.In
    | token.ThinArrow
    | token.FatArrow
    | token.Dot
    -> True
    _ -> False
  }
}
