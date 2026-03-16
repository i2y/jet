pub type JetError {
  LexError(line: Int, message: String)
  ParseError(line: Int, expected: String, got: String)
  CodegenError(line: Int, message: String)
  FileError(path: String, reason: String)
}

pub fn format(error: JetError) -> String {
  case error {
    LexError(line, message) ->
      "Lex error on line " <> int_to_string(line) <> ": " <> message
    ParseError(line, expected, got) ->
      "Parse error on line "
      <> int_to_string(line)
      <> ": expected "
      <> expected
      <> ", got "
      <> got
    CodegenError(line, message) ->
      "Codegen error on line " <> int_to_string(line) <> ": " <> message
    FileError(path, reason) -> "File error (" <> path <> "): " <> reason
  }
}

@external(erlang, "erlang", "integer_to_list")
fn int_to_string_charlist(n: Int) -> List(Int)

fn int_to_string(n: Int) -> String {
  let chars = int_to_string_charlist(n)
  charlist_to_string(chars)
}

@external(erlang, "erlang", "list_to_binary")
fn charlist_to_string(chars: List(Int)) -> String
