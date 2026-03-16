import gleeunit
import gleeunit/should
import jet/lexer
import jet/token

pub fn main() {
  gleeunit.main()
}

pub fn lex_integer_test() {
  let assert Ok(tokens) = lexer.lex("42")
  let assert [#(token.Int(42), _)] = tokens
}

pub fn lex_float_test() {
  let assert Ok(tokens) = lexer.lex("3.14")
  let assert [#(token.Float(v), _)] = tokens
  should.be_true(v >. 3.13 && v <. 3.15)
}

pub fn lex_string_test() {
  let assert Ok(tokens) = lexer.lex("\"hello\"")
  let assert [#(token.Str("hello"), _)] = tokens
}

pub fn lex_atom_test() {
  let assert Ok(tokens) = lexer.lex(":foo")
  let assert [#(token.Atom("foo"), _)] = tokens
}

pub fn lex_keywords_test() {
  let assert Ok(tokens) = lexer.lex("module class def end")
  let assert [
    #(token.Module, _),
    #(token.Class, _),
    #(token.Def, _),
    #(token.End, _),
  ] = tokens
}

pub fn lex_operators_test() {
  let assert Ok(tokens) = lexer.lex("+ - * / == != <= >=")
  let assert [
    #(token.Plus, _),
    #(token.Minus, _),
    #(token.Star, _),
    #(token.Slash, _),
    #(token.EqEq, _),
    #(token.BangEq, _),
    #(token.LtEq, _),
    #(token.GtEq, _),
  ] = tokens
}

pub fn lex_self_dot_test() {
  let assert Ok(tokens) = lexer.lex("self.name")
  let assert [#(token.SelfDot, _), #(token.Name("name"), _)] = tokens
}

pub fn lex_pipeline_test() {
  let assert Ok(tokens) = lexer.lex("|> |>>")
  let assert [#(token.Pipeline, _), #(token.LastPipeline, _)] = tokens
}

pub fn lex_binary_begin_end_test() {
  let assert Ok(tokens) = lexer.lex("<< >>")
  let assert [#(token.BinaryBegin, _), #(token.BinaryEnd, _)] = tokens
}

pub fn lex_comment_test() {
  let assert Ok(tokens) = lexer.lex("42 # this is a comment\n43")
  let assert [#(token.Int(42), _), #(token.Newline, _), #(token.Int(43), _)] =
    tokens
}

pub fn lex_name_test() {
  let assert Ok(tokens) = lexer.lex("foo_bar")
  let assert [#(token.Name("foo_bar"), _)] = tokens
}

pub fn lex_based_integer_test() {
  let assert Ok(tokens) = lexer.lex("16$FF")
  let assert [#(token.Int(255), _)] = tokens
}

pub fn lex_pow_test() {
  let assert Ok(tokens) = lexer.lex("**")
  let assert [#(token.Pow, _)] = tokens
}

pub fn lex_floordiv_test() {
  let assert Ok(tokens) = lexer.lex("floordiv")
  let assert [#(token.FloorDiv, _)] = tokens
}
