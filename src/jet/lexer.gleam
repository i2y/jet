import gleam/int
import gleam/list

import gleam/string
import jet/error
import jet/token.{type Position, type Token, Position}

pub type LexResult =
  Result(List(#(Token, Position)), error.JetError)

type LexerState {
  LexerState(remaining: String, line: Int, tokens: List(#(Token, Position)))
}

pub fn lex(source: String) -> LexResult {
  do_lex(LexerState(remaining: source, line: 1, tokens: []))
}

fn do_lex(state: LexerState) -> LexResult {
  case string.pop_grapheme(state.remaining) {
    Error(_) -> Ok(list.reverse(state.tokens))
    Ok(#(char, rest)) -> lex_char(state, char, rest)
  }
}

fn lex_char(state: LexerState, char: String, rest: String) -> LexResult {
  case char {
    // Whitespace (spaces and tabs)
    " " | "\t" -> do_lex(LexerState(..state, remaining: rest))

    // Newlines
    "\n" ->
      do_lex(LexerState(
        remaining: rest,
        line: state.line + 1,
        tokens: [#(token.Newline, Position(state.line)), ..state.tokens],
      ))
    "\r" -> lex_cr(state, rest)

    // Comments
    "#" -> do_lex(LexerState(..state, remaining: skip_to_eol(rest)))

    // Two-character operators
    "|" -> lex_pipe(state, rest)
    "+" -> lex_plus(state, rest)
    "-" -> lex_minus(state, rest)
    "*" -> lex_star(state, rest)
    "=" -> lex_equals(state, rest)
    "!" -> lex_bang(state, rest)
    "<" -> lex_lt(state, rest)
    ">" -> lex_gt(state, rest)
    "." -> lex_dot(state, rest)
    ":" -> lex_colon(state, rest)

    // Single-character tokens
    "(" -> emit(state, rest, token.LParen)
    ")" -> emit(state, rest, token.RParen)
    "[" -> emit(state, rest, token.LBrack)
    "]" -> emit(state, rest, token.RBrack)
    "{" -> emit(state, rest, token.LBrace)
    "}" -> emit(state, rest, token.RBrace)
    "," -> emit(state, rest, token.Comma)
    ";" -> emit(state, rest, token.Semi)
    "@" -> emit(state, rest, token.At)
    "&" -> emit(state, rest, token.Amp)
    "\\" -> emit(state, rest, token.Backslash)
    "^" -> emit(state, rest, token.Caret)
    "/" -> emit(state, rest, token.Slash)
    "%" -> lex_percent(state, rest)

    // String literals
    "\"" -> lex_string(state, rest, "")

    // Digits
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" ->
      lex_number(state, rest, char)

    // Identifiers and keywords
    _ ->
      case is_ident_start(char) {
        True -> lex_identifier(state, rest, char)
        False ->
          Error(error.LexError(state.line, "Unexpected character: " <> char))
      }
  }
}

fn lex_cr(state: LexerState, rest: String) -> LexResult {
  let #(new_rest, new_line) = case string.pop_grapheme(rest) {
    Ok(#("\n", r)) -> #(r, state.line + 1)
    _ -> #(rest, state.line + 1)
  }
  do_lex(LexerState(
    remaining: new_rest,
    line: new_line,
    tokens: [#(token.Newline, Position(state.line)), ..state.tokens],
  ))
}

fn emit(
  state: LexerState,
  rest: String,
  tok: Token,
) -> LexResult {
  do_lex(
    LexerState(
      remaining: rest,
      line: state.line,
      tokens: [#(tok, Position(state.line)), ..state.tokens],
    ),
  )
}

fn skip_to_eol(s: String) -> String {
  case string.pop_grapheme(s) {
Error(_) -> ""
    Ok(#("\n", _)) -> s
    Ok(#("\r", _)) -> s
    Ok(#(_, rest)) -> skip_to_eol(rest)
  }
}

fn is_ident_start(c: String) -> Bool {
  case c {
    "_" | "$" -> True
    _ -> is_alpha(c)
  }
}

fn is_ident_char(c: String) -> Bool {
  case c {
    "_" | "-" | "?" | "!" | "$" -> True
    _ -> is_alpha(c) || is_digit(c)
  }
}

fn is_alpha(c: String) -> Bool {
  case c {
    "a" | "b" | "c" | "d" | "e" | "f" | "g" | "h" | "i" | "j" | "k" | "l"
    | "m" | "n" | "o" | "p" | "q" | "r" | "s" | "t" | "u" | "v" | "w" | "x"
    | "y" | "z" | "A" | "B" | "C" | "D" | "E" | "F" | "G" | "H" | "I" | "J"
    | "K" | "L" | "M" | "N" | "O" | "P" | "Q" | "R" | "S" | "T" | "U" | "V"
    | "W" | "X" | "Y" | "Z" -> True
    _ -> False
  }
}

fn is_digit(c: String) -> Bool {
  case c {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

fn is_hex_digit(c: String) -> Bool {
  is_digit(c)
  || case c {
    "a" | "b" | "c" | "d" | "e" | "f" | "A" | "B" | "C" | "D" | "E" | "F" ->
      True
    _ -> False
  }
}

fn is_alnum(c: String) -> Bool {
  is_alpha(c) || is_digit(c)
}

// --- Pipe/Pipeline ---
fn lex_pipe(state: LexerState, rest: String) -> LexResult {
  case string.pop_grapheme(rest) {
Ok(#(">", rest2)) ->
      case string.pop_grapheme(rest2) {
    Ok(#(">", rest3)) -> emit(state, rest3, token.LastPipeline)
        _ -> emit(state, rest2, token.Pipeline)
      }
    _ -> emit(state, rest, token.Pipe)
  }
}

// --- Plus ---
fn lex_plus(state: LexerState, rest: String) -> LexResult {
  case string.pop_grapheme(rest) {
Ok(#("+", rest2)) -> emit(state, rest2, token.PlusPlus)
    _ -> emit(state, rest, token.Plus)
  }
}

// --- Minus ---
fn lex_minus(state: LexerState, rest: String) -> LexResult {
  case string.pop_grapheme(rest) {
Ok(#(">", rest2)) -> emit(state, rest2, token.ThinArrow)
    _ -> emit(state, rest, token.Minus)
  }
}

// --- Star ---
fn lex_star(state: LexerState, rest: String) -> LexResult {
  case string.pop_grapheme(rest) {
Ok(#("*", rest2)) -> emit(state, rest2, token.Pow)
    _ -> emit(state, rest, token.Star)
  }
}

// --- Equals ---
fn lex_equals(state: LexerState, rest: String) -> LexResult {
  case string.pop_grapheme(rest) {
Ok(#("=", rest2)) -> emit(state, rest2, token.EqEq)
    Ok(#(">", rest2)) -> emit(state, rest2, token.FatArrow)
    _ -> emit(state, rest, token.Equals)
  }
}

// --- Bang ---
fn lex_bang(state: LexerState, rest: String) -> LexResult {
  case string.pop_grapheme(rest) {
Ok(#("=", rest2)) -> emit(state, rest2, token.BangEq)
    _ -> emit(state, rest, token.Bang)
  }
}

// --- Less than ---
fn lex_lt(state: LexerState, rest: String) -> LexResult {
  case string.pop_grapheme(rest) {
Ok(#("=", rest2)) -> emit(state, rest2, token.LtEq)
    Ok(#("<", rest2)) -> emit(state, rest2, token.BinaryBegin)
    _ -> emit(state, rest, token.Lt)
  }
}

// --- Greater than ---
fn lex_gt(state: LexerState, rest: String) -> LexResult {
  case string.pop_grapheme(rest) {
Ok(#("=", rest2)) -> emit(state, rest2, token.GtEq)
    Ok(#(">", rest2)) -> emit(state, rest2, token.BinaryEnd)
    _ -> emit(state, rest, token.Gt)
  }
}

// --- Dot ---
fn lex_dot(state: LexerState, rest: String) -> LexResult {
  case string.pop_grapheme(rest) {
Ok(#(".", rest2)) -> emit(state, rest2, token.DotDot)
    _ -> emit(state, rest, token.Dot)
  }
}

// --- Colon ---
fn lex_colon(state: LexerState, rest: String) -> LexResult {
  case string.pop_grapheme(rest) {
Ok(#(":", rest2)) -> emit(state, rest2, token.ColonColon)
    Ok(#(c, rest2)) ->
      case is_ident_start(c) {
        True -> lex_atom(state, rest2, c)
        False -> emit(state, rest, token.Colon)
      }
    _ -> emit(state, rest, token.Colon)
  }
}

// --- Percent ---
fn lex_percent(state: LexerState, rest: String) -> LexResult {
  emit(state, rest, token.Percent)
}

// --- Atom literal :name ---
fn lex_atom(state: LexerState, rest: String, first: String) -> LexResult {
  let #(name, remaining) = collect_ident(rest, first)
  do_lex(
    LexerState(
      remaining: remaining,
      line: state.line,
      tokens: [#(token.Atom(name), Position(state.line)), ..state.tokens],
    ),
  )
}

// --- String literal ---
fn lex_string(
  state: LexerState,
  rest: String,
  acc: String,
) -> LexResult {
  case string.pop_grapheme(rest) {
Error(_) -> Error(error.LexError(state.line, "Unterminated string"))
    Ok(#("\"", rest2)) ->
      do_lex(
        LexerState(
          remaining: rest2,
          line: state.line,
          tokens: [
            #(token.Str(acc), Position(state.line)),
            ..state.tokens
          ],
        ),
      )
    Ok(#("\\", rest2)) -> {
      case string.pop_grapheme(rest2) {
    Error(_) -> Error(error.LexError(state.line, "Unterminated string escape"))
        Ok(#("n", rest3)) -> lex_string(state, rest3, acc <> "\n")
        Ok(#("t", rest3)) -> lex_string(state, rest3, acc <> "\t")
        Ok(#("r", rest3)) -> lex_string(state, rest3, acc <> "\r")
        Ok(#("\\", rest3)) -> lex_string(state, rest3, acc <> "\\")
        Ok(#("\"", rest3)) -> lex_string(state, rest3, acc <> "\"")
        Ok(#("x", rest3)) -> lex_hex_escape(state, rest3, acc)
        Ok(#(c, rest3)) -> lex_string(state, rest3, acc <> "\\" <> c)
      }
    }
    Ok(#("\n", rest2)) ->
      lex_string(
        LexerState(..state, line: state.line + 1),
        rest2,
        acc <> "\n",
      )
    Ok(#(c, rest2)) -> lex_string(state, rest2, acc <> c)
  }
}

fn lex_hex_escape(
  state: LexerState,
  rest: String,
  acc: String,
) -> LexResult {
  let #(hex_str, remaining) = collect_hex(rest, "")
  case string.pop_grapheme(remaining) {
Ok(#(";", rest2)) -> {
      case parse_hex_int(hex_str) {
    Ok(code) -> {
          let char = codepoint_to_string(code)
          lex_string(state, rest2, acc <> char)
        }
        Error(_) ->
          Error(error.LexError(state.line, "Invalid hex escape: \\x" <> hex_str))
      }
    }
    _ -> {
      case parse_hex_int(hex_str) {
    Ok(code) -> {
          let char = codepoint_to_string(code)
          lex_string(state, remaining, acc <> char)
        }
        Error(_) ->
          Error(error.LexError(state.line, "Invalid hex escape: \\x" <> hex_str))
      }
    }
  }
}

fn collect_hex(s: String, acc: String) -> #(String, String) {
  case string.pop_grapheme(s) {
Ok(#(c, rest)) ->
      case is_hex_digit(c) {
        True -> collect_hex(rest, acc <> c)
        False -> #(acc, s)
      }
    _ -> #(acc, s)
  }
}

// --- Number literals ---
fn lex_number(
  state: LexerState,
  rest: String,
  first: String,
) -> LexResult {
  let #(digits, remaining) = collect_digits(rest, first)
  case string.pop_grapheme(remaining) {
// Integer with base: 16$FF
    Ok(#("$", rest2)) -> {
      case int.parse(digits) {
    Ok(base) -> {
          let #(based_digits, remaining2) = collect_based_digits(rest2, "")
          case parse_based_int(based_digits, base) {
        Ok(value) ->
              do_lex(
                LexerState(
                  remaining: remaining2,
                  line: state.line,
                  tokens: [
                    #(token.Int(value), Position(state.line)),
                    ..state.tokens
                  ],
                ),
              )
            Error(_) ->
              Error(error.LexError(
                state.line,
                "Invalid based integer: " <> digits <> "$" <> based_digits,
              ))
          }
        }
        Error(_) ->
          Error(error.LexError(
            state.line,
            "Invalid base for integer: " <> digits,
          ))
      }
    }
    // Float: 123.456
    Ok(#(".", rest2)) -> {
      case string.pop_grapheme(rest2) {
    Ok(#(c, _)) ->
          case is_digit(c) {
            True -> {
              let #(frac_digits, remaining2) = collect_digits(rest2, "")
              let float_str = digits <> "." <> frac_digits
              // Check for exponent
              let #(full_str, final_rest) =
                lex_exponent(remaining2, float_str)
              case parse_float_string(full_str) {
            Ok(value) ->
                  do_lex(
                    LexerState(
                      remaining: final_rest,
                      line: state.line,
                      tokens: [
                        #(token.Float(value), Position(state.line)),
                        ..state.tokens
                      ],
                    ),
                  )
                Error(_) ->
                  Error(error.LexError(
                    state.line,
                    "Invalid float: " <> full_str,
                  ))
              }
            }
            // Not a float, it's int followed by ..
            False -> {
              case int.parse(digits) {
            Ok(value) ->
                  do_lex(
                    LexerState(
                      remaining: remaining,
                      line: state.line,
                      tokens: [
                        #(token.Int(value), Position(state.line)),
                        ..state.tokens
                      ],
                    ),
                  )
                Error(_) ->
                  Error(error.LexError(
                    state.line,
                    "Invalid integer: " <> digits,
                  ))
              }
            }
          }
        Error(_) -> {
          // EOF after "123." - treat as integer followed by dot
          case int.parse(digits) {
        Ok(value) ->
              do_lex(
                LexerState(
                  remaining: remaining,
                  line: state.line,
                  tokens: [
                    #(token.Int(value), Position(state.line)),
                    ..state.tokens
                  ],
                ),
              )
            Error(_) ->
              Error(error.LexError(
                state.line,
                "Invalid integer: " <> digits,
              ))
          }
        }
      }
    }
    _ -> {
      case int.parse(digits) {
    Ok(value) ->
          do_lex(
            LexerState(
              remaining: remaining,
              line: state.line,
              tokens: [
                #(token.Int(value), Position(state.line)),
                ..state.tokens
              ],
            ),
          )
        Error(_) ->
          Error(error.LexError(state.line, "Invalid integer: " <> digits))
      }
    }
  }
}

fn lex_exponent(s: String, acc: String) -> #(String, String) {
  case string.pop_grapheme(s) {
Ok(#("e", rest)) | Ok(#("E", rest)) -> {
      case string.pop_grapheme(rest) {
    Ok(#("+", rest2)) -> {
          let #(exp_digits, remaining) = collect_digits(rest2, "")
          #(acc <> "e+" <> exp_digits, remaining)
        }
        Ok(#("-", rest2)) -> {
          let #(exp_digits, remaining) = collect_digits(rest2, "")
          #(acc <> "e-" <> exp_digits, remaining)
        }
        Ok(#(c, _)) ->
          case is_digit(c) {
            True -> {
              let #(exp_digits, remaining) = collect_digits(rest, "")
              #(acc <> "e" <> exp_digits, remaining)
            }
            False -> #(acc, s)
          }
        _ -> #(acc, s)
      }
    }
    _ -> #(acc, s)
  }
}

fn collect_digits(s: String, acc: String) -> #(String, String) {
  case string.pop_grapheme(s) {
Ok(#(c, rest)) ->
      case is_digit(c) {
        True -> collect_digits(rest, acc <> c)
        False -> #(acc, s)
      }
    _ -> #(acc, s)
  }
}

fn collect_based_digits(s: String, acc: String) -> #(String, String) {
  case string.pop_grapheme(s) {
Ok(#(c, rest)) ->
      case is_alnum(c) {
        True -> collect_based_digits(rest, acc <> c)
        False -> #(acc, s)
      }
    _ -> #(acc, s)
  }
}

// --- Identifiers and keywords ---
fn lex_identifier(
  state: LexerState,
  rest: String,
  first: String,
) -> LexResult {
  let #(name, remaining) = collect_ident(rest, first)
  // Check for self. (special token)
  case name {
    "self" ->
      case string.pop_grapheme(remaining) {
    Ok(#(".", rest2)) ->
          // Check if followed by identifier char (self.method) vs self.. (range)
          case string.pop_grapheme(rest2) {
        Ok(#(c, _)) ->
              case is_ident_start(c) {
                True -> emit(state, rest2, token.SelfDot)
                False ->
                  // self followed by dot - emit as Name("self") then Dot
                  do_lex(
                    LexerState(
                      remaining: remaining,
                      line: state.line,
                      tokens: [
                        #(token.Name("self"), Position(state.line)),
                        ..state.tokens
                      ],
                    ),
                  )
              }
            Error(_) ->
              do_lex(
                LexerState(
                  remaining: remaining,
                  line: state.line,
                  tokens: [
                    #(token.Name("self"), Position(state.line)),
                    ..state.tokens
                  ],
                ),
              )
          }
        _ ->
          do_lex(
            LexerState(
              remaining: remaining,
              line: state.line,
              tokens: [
                #(token.Name("self"), Position(state.line)),
                ..state.tokens
              ],
            ),
          )
      }
    _ -> {
      let tok = keyword_or_name(name)
      do_lex(
        LexerState(
          remaining: remaining,
          line: state.line,
          tokens: [#(tok, Position(state.line)), ..state.tokens],
        ),
      )
    }
  }
}

fn collect_ident(s: String, acc: String) -> #(String, String) {
  case string.pop_grapheme(s) {
Ok(#(c, rest)) ->
      case is_ident_char(c) {
        True -> collect_ident(rest, acc <> c)
        False -> #(acc, s)
      }
    _ -> #(acc, s)
  }
}

fn keyword_or_name(name: String) -> Token {
  case name {
    "module" -> token.Module
    "class" -> token.Class
    "def" -> token.Def
    "if" -> token.If
    "elsif" -> token.Elsif
    "else" -> token.Else
    "then" -> token.Then
    "case" -> token.Case
    "match" -> token.Match
    "receive" -> token.Receive
    "after" -> token.After
    "try" -> token.Try
    "catch" -> token.Catch
    "raise" -> token.Raise
    "finally" -> token.Finally
    "as" -> token.As
    "for" -> token.For
    "in" -> token.In
    "do" -> token.Do
    "end" -> token.End
    "import" -> token.Import
    "include" -> token.Include
    "require" -> token.Require
    "export" -> token.Export
    "export_all" -> token.ExportAll
    "record" -> token.Record
    "patterns" -> token.Patterns
    "vector" -> token.Vector
    "of" -> token.Of
    "meta" -> token.Meta
    "behavior" -> token.Behavior
    "and" -> token.And
    "or" -> token.Or
    "xor" -> token.Xor
    "is" -> token.Is
    "not" -> token.Not
    "band" -> token.Band
    "bor" -> token.Bor
    "bxor" -> token.Bxor
    "bnot" -> token.Bnot
    "bsl" -> token.Bsl
    "bsr" -> token.Bsr
    "floordiv" -> token.FloorDiv
    "needs" -> token.Needs
    "platform" -> token.Platform
    "provide" -> token.Provide
    "using" -> token.Using
    "expose" -> token.Expose
    "peers" -> token.Peers
    "actor" -> token.Actor
    "nil" -> token.Nil
    "true" -> token.True
    "false" -> token.False
    "test" -> token.Name("test")
    "protocol" -> token.Name("protocol")
    _ -> token.Name(name)
  }
}

// --- FFI helpers ---

@external(erlang, "jet_ffi", "string_to_charlist")
fn string_to_charlist(s: String) -> List(Int)

@external(erlang, "erlang", "list_to_integer")
fn charlist_to_int_base(chars: List(Int), base: Int) -> Int

@external(erlang, "erlang", "list_to_float")
fn charlist_to_float(chars: List(Int)) -> Float

fn parse_hex_int(s: String) -> Result(Int, Nil) {
  let chars = string_to_charlist(s)
  case chars {
    [] -> Error(Nil)
    _ -> Ok(do_parse_hex(chars))
  }
}

fn do_parse_hex(chars: List(Int)) -> Int {
  charlist_to_int_base(chars, 16)
}

fn parse_based_int(digits: String, base: Int) -> Result(Int, Nil) {
  let chars = string_to_charlist(digits)
  case chars {
    [] -> Error(Nil)
    _ -> Ok(charlist_to_int_base(chars, base))
  }
}

fn parse_float_string(s: String) -> Result(Float, Nil) {
  let chars = string_to_charlist(s)
  case chars {
    [] -> Error(Nil)
    _ -> Ok(charlist_to_float(chars))
  }
}

@external(erlang, "jet_ffi", "codepoint_to_string")
fn codepoint_to_string(code: Int) -> String
