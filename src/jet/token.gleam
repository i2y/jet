pub type Position {
  Position(line: Int)
}

pub type Token {
  // Literals
  Int(value: Int)
  Float(value: Float)
  Str(value: String)
  Atom(value: String)
  Name(value: String)
  True
  False
  Nil

  // Keywords
  Module
  Class
  Def
  If
  Elsif
  Else
  Then
  Case
  Match
  Receive
  After
  Try
  Catch
  Raise
  Finally
  As
  For
  In
  Do
  End
  Import
  Include
  Require
  Export
  ExportAll
  Record
  Patterns
  Vector
  Of
  Meta
  Behavior
  N2Class
  Needs
  Platform
  Provide
  Using
  Expose
  Peers
  Actor

  // Operators
  Plus
  Minus
  Star
  Slash
  FloorDiv
  Pow
  Percent
  PlusPlus
  EqEq
  BangEq
  Lt
  Gt
  LtEq
  GtEq
  Band
  Bor
  Bxor
  Bnot
  Bsl
  Bsr
  And
  Or
  Xor
  Is
  Not
  Bang
  Equals
  Pipe
  Pipeline
  LastPipeline
  DotDot
  Dot
  ColonColon
  ThinArrow
  FatArrow

  // Delimiters
  LParen
  RParen
  LBrack
  RBrack
  LBrace
  RBrace
  BinaryBegin
  BinaryEnd
  Comma
  Colon
  Semi

  // Special
  At
  Amp
  Backslash
  Caret
  Sharp
  Newline
  SelfDot
}

pub fn token_name(tok: Token) -> String {
  case tok {
    Int(_) -> "integer"
    Float(_) -> "float"
    Str(_) -> "string"
    Atom(_) -> "atom"
    Name(_) -> "name"
    True -> "true"
    False -> "false"
    Nil -> "nil"
    Module -> "module"
    Class -> "class"
    Def -> "def"
    If -> "if"
    Elsif -> "elsif"
    Else -> "else"
    Then -> "then"
    Case -> "case"
    Match -> "match"
    Receive -> "receive"
    After -> "after"
    Try -> "try"
    Catch -> "catch"
    Raise -> "raise"
    Finally -> "finally"
    As -> "as"
    For -> "for"
    In -> "in"
    Do -> "do"
    End -> "end"
    Import -> "import"
    Include -> "include"
    Require -> "require"
    Export -> "export"
    ExportAll -> "export_all"
    Record -> "record"
    Patterns -> "patterns"
    Vector -> "vector"
    Of -> "of"
    Meta -> "meta"
    Behavior -> "behavior"
    N2Class -> "n2class"
    Needs -> "needs"
    Platform -> "platform"
    Provide -> "provide"
    Using -> "using"
    Expose -> "expose"
    Peers -> "peers"
    Actor -> "actor"
    Plus -> "+"
    Minus -> "-"
    Star -> "*"
    Slash -> "/"
    FloorDiv -> "floordiv"
    Pow -> "**"
    Percent -> "%"
    PlusPlus -> "++"
    EqEq -> "=="
    BangEq -> "!="
    Lt -> "<"
    Gt -> ">"
    LtEq -> "<="
    GtEq -> ">="
    Band -> "band"
    Bor -> "bor"
    Bxor -> "bxor"
    Bnot -> "bnot"
    Bsl -> "bsl"
    Bsr -> "bsr"
    And -> "and"
    Or -> "or"
    Xor -> "xor"
    Is -> "is"
    Not -> "not"
    Bang -> "!"
    Equals -> "="
    Pipe -> "|"
    Pipeline -> "|>"
    LastPipeline -> "|>>"
    DotDot -> ".."
    Dot -> "."
    ColonColon -> "::"
    ThinArrow -> "->"
    FatArrow -> "=>"
    LParen -> "("
    RParen -> ")"
    LBrack -> "["
    RBrack -> "]"
    LBrace -> "{"
    RBrace -> "}"
    BinaryBegin -> "<<"
    BinaryEnd -> ">>"
    Comma -> ","
    Colon -> ":"
    Semi -> ";"
    At -> "@"
    Amp -> "&"
    Backslash -> "\\"
    Caret -> "^"
    Sharp -> "#"
    Newline -> "newline"
    SelfDot -> "self."
  }
}
