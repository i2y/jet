-module(jet_parser_ffi).
-export([string_drop_first/1]).

string_drop_first(<<>>) -> <<>>;
string_drop_first(<<_/utf8, Rest/binary>>) -> Rest.
