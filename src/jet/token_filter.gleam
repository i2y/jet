import gleam/list
import jet/token.{type Position, type Token}

/// Filter tokens: replace __name__ with module name atom,
/// remove newlines before infix operators and after commas.
pub fn filter(
  tokens: List(#(Token, Position)),
  module_name: String,
) -> List(#(Token, Position)) {
  tokens
  |> list.map(fn(t) {
    case t {
      #(token.Name("__name__"), pos) -> #(token.Atom(module_name), pos)
      other -> other
    }
  })
  |> remove_extraneous_newlines()
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
