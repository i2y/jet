Definitions.

INT = [0-9]+
INT_WITH_BASE = [0-9]+\$[0-9a-zA-Z]+
ATOM = :[_a-zA-Z$][-_a-zA-Z0-9]*
WHITESPACE = [\s\t]|#[^\n]*
NEWLINE = [\n\r]

STR = "(\\x[0-9a-fA-F]+;|\\.|[^"])*"
LAST_PIPELINE = \|>>
PIPELINE = \|>
CONS = \|
OPBITAND = band
OPBITOR  = bor
OPBITXOR = bxor
OPBITNOT = bnot
OPBITSL = bsl
OPBITSR = bsr
OPFLOORDIV = floordib
OPPOW = \*\*
LBRACK = \[
RBRACK = \]
LBRACE = \{
RBRACE = \}
LPAREN = \(
RPAREN = \)
BINARY_BEGIN = <<
BINARY_END = >>
PERCENT = %
COMMA = ,
THIN_ARROW = ->
FAT_ARROW = \=>
COLON_COLON = ::
COLON = :
CALET = \^
OPAPPEND = \+\+
OPPLUS = \+
OPMINUS = -
OPTIMES = \*
OPDIV = /
OPLEQ = <\=
OPGEQ = >\=
OPEQ = \=\=
OPNEQ = !\=
OPLT = <
OPGT = >
BANG = !
EQUALS = \=
SEMI = ;
DO = do
END = end
AT = @
SHARP = #
AMP = \&
BACKSLASH = \\
IMPORT = import
INCLUDE = include
MODULE = module
CLASS = class
BEHAVIOR = behavior
REQUIRE = require
EXPORT = export
EXPORT_ALL = export_all
DEF = def
NEW = new
TRY = try
EXCEPT = except
AS = as
FINALLY = finally
RAISE = raise
IF = if
ELSE = else
ELSEIF = elif
THEN = then
MATCH = match
CASE = case
RECEIVE = receive
AFTER = after
OF = of
VECTOR = vector
RECORD = record
PATTERNS = patterns
YIELD = yield
RETURN = return
WITH = with
FOR = for
IN = in
FROM = from
OPAND = and
OPOR = or
OPXOR = xor
OPIS = is
NOT = not
NIL = nil
TRUE = true
FALSE = false
SELF_DOT = self\.
DOT = \.
NAME = [_a-zA-Z$][-_a-zA-Z0-9?!]*


Rules.

{COMMENT}+ : skipToken. % {token, {comment, TokenLine, TokenChars}}.
{LAST_PIPELINE} : {token, {last_pipeline, TokenLine}}.
{PIPELINE} : {token, {pipeline, TokenLine}}.
{CONS} : {token, {cons, TokenLine}}.
{OPBITAND} : {token, {op_bitand, TokenLine}}.
{OPBITOR} : {token, {op_bitor, TokenLine}}.
{OPBITXOR} : {token, {op_bitxor, TokenLine}}.
{OPBITNOT} : {token, {op_bitnot, TokenLine}}.
{OPBITSL} : {token, {op_bitsl, TokenLine}}.
{OPBITSR} : {token, {op_bitsr, TokenLine}}.
{OPFLOORDIV} : {token, {op_floor_div, TokenLine}}.
{OPPOW} : {token, {op_pow, TokenLine}}.
{LBRACK} : {token, {lbrack, TokenLine}}.
{RBRACK} : {token, {rbrack, TokenLine}}.
{LBRACE} : {token, {lbrace, TokenLine}}.
{RBRACE} : {token, {rbrace, TokenLine}}.
{LPAREN} : {token, {lparen, TokenLine}}.
{RPAREN} : {token, {rparen, TokenLine}}.
{BINARY_BEGIN} : {token, {binary_begin, TokenLine}}.
{BINARY_END} : {token, {binary_end, TokenLine}}.
{PERCENT} : {token, {percent, TokenLine}}.
{COMMA} : {token, {comma, TokenLine}}.
{THIN_ARROW} : {token, {thin_arrow, TokenLine}}.
{FAT_ARROW} : {token, {fat_arrow, TokenLine}}.
{COLON_COLON} : {token, {colon_colon, TokenLine}}.
{COLON} : {token, {colon, TokenLine}}.
{CALET} : {token, {calet, TokenLine}}.
{OPPLUS} : {token, {op_plus, TokenLine}}.
{OPMINUS} : {token, {op_minus, TokenLine}}.
{OPTIMES} : {token, {op_times, TokenLine}}.
{OPDIV} : {token, {op_div, TokenLine}}.
{OPAPPEND} : {token, {op_append, TokenLine}}.
{OPREMOVE} : {token, {op_remove, TokenLine}}.
{OPLEQ} : {token, {op_leq, TokenLine}}.
{OPGEQ} : {token, {op_geq, TokenLine}}.
{OPEQ} : {token, {op_eq, TokenLine}}.
{OPNEQ} : {token, {op_neq, TokenLine}}.
{OPLT} : {token, {op_lt, TokenLine}}.
{OPGT} : {token, {op_gt, TokenLine}}.
{BANG} : {token, {bang, TokenLine}}.
{EQUALS} : {token, {equals, TokenLine}}.
{SEMI} : {token, {semi, TokenLine}}.
{DO} : {token, {do, TokenLine}}.
{END} : {token, {end_keyword, TokenLine}}.
{AT} : {token, {at, TokenLine}}.
{AMP} : {token, {amp, TokenLine}}.
{BACKSLASH} : {token, {backslash, TokenLine}}.
{IMPORT} : {token, {import_keyword, TokenLine}}.
{INCLUDE} : {token, {include_keyword, TokenLine}}.
{MODULE} : {token, {module_keyword, TokenLine}}.
{CLASS} : {token, {class_keyword, TokenLine}}.
{BEHAVIOR} : {token, {behavior, TokenLine}}.
{REQUIRE} : {token, {require, TokenLine}}.
{EXPORT} : {token, {export_keyword, TokenLine}}.
{EXPORT_ALL} : {token, {export_all, TokenLine}}.
{DEF} : {token, {def_keyword, TokenLine}}.
{NEW} : {token, {new, TokenLine}}.
{TRY} : {token, {try_keyword, TokenLine}}.
{EXCEPT} : {token, {except_keyword, TokenLine}}.
{AS} : {token, {as, TokenLine}}.
{FINALLY} : {token, {finally_keyword, TokenLine}}.
{RAISE} : {token, {raise_keyword, TokenLine}}.
{IF} : {token, {if_keyword, TokenLine}}.
{ELSE} : {token, {else_keyword, TokenLine}}.
{ELSEIF} : {token, {elseif_keyword, TokenLine}}.
{THEN} : {token, {then, TokenLine}}.
{MATCH} : {token, {match_keyword, TokenLine}}.
{CASE} : {token, {case_keyword, TokenLine}}.
{PATTERNS} : {token, {patterns, TokenLine}}.
{RECEIVE} : {token, {receive_keyword, TokenLine}}.
{AFTER} : {token, {after_keyword, TokenLine}}.
{OF} : {token, {of_keyword, TokenLine}}.
{VECTOR} : {token, {vector_keyword, TokenLine}}.
{RECORD} : {token, {record_keyword, TokenLine}}.
{SHARP} : {token, {sharp, TokenLine}}.
{NOT} : {token, {not_keyword, TokenLine}}.
{YIELD} : {token, {yield, TokenLine}}.
{WITH} : {token, {with, TokenLine}}.
{FOR} : {token, {for, TokenLine}}.
{IN} : {token, {in, TokenLine}}.
{FROM} : {token, {from, TokenLine}}.
{OPAND} : {token, {op_and, TokenLine}}.
{OPOR} : {token, {op_or, TokenLine}}.
{OPXOR} : {token, {op_xor, TokenLine}}.
{OPIS} : {token, {op_is, TokenLine}}.
{NOT} : {token, {op_not, TokenLine}}.
{NIL} : {token, {nil, TokenLine}}.
{TRUE} : {token, {true, TokenLine}}.
{FALSE} : {token, {false, TokenLine}}.
(\+|\-)?{INT} : {token, {int, TokenLine, list_to_integer(TokenChars)}}.
(\+|\-)?{INT_WITH_BASE} : {token, {int, TokenLine, to_integer(TokenChars)}}.
{ATOM} : {token, {atom, TokenLine, to_atom(TokenChars)}}.
(\+|\-)?{INT}+\.{INT}+((E|e)(\+|\-)?{INT}+)? : {token, {float, TokenLine, list_to_float(TokenChars)}}.
{SELF_DOT} : {token, {self_dot, TokenLine}}.
{DOT} : {token, {dot, TokenLine}}.
{NAME} : {token, {name, TokenLine, TokenChars}}.
{STR} : {token, {str, TokenLine, TokenChars}}.
{NEWLINE} : {token, {newline, TokenLine, TokenChars}}.
{WHITESPACE}+ : skip_token.

Erlang code.

to_atom([$:|Chars]) ->
    list_to_atom(Chars).

to_integer(Chars) ->
    SharpPos = string:chr(Chars, $$) - 1,
    Base = list_to_integer(string:sub_string(Chars, 1, SharpPos)),
    list_to_integer(string:sub_string(Chars, SharpPos + 2), Base).
