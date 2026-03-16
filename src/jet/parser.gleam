import gleam/list
import gleam/option.{type Option, None, Some}
import jet/ast.{
  type BinOperator, type Expr, type FuncContext, type Module, type TopLevel,
}
import jet/error
import jet/token.{type Position, type Token, Position}

// --- Parser State ---

type Parser {
  Parser(
    tokens: List(#(Token, Position)),
    module_name: String,
    context_stack: List(FuncContext),
  )
}

type ParseResult(a) =
  Result(#(a, Parser), error.JetError)

// --- Public API ---

pub fn parse(
  tokens: List(#(Token, Position)),
  module_name: String,
) -> Result(Module, error.JetError) {
  let parser = Parser(tokens: tokens, module_name: module_name, context_stack: [])
  case parse_module(parser) {
    Ok(#(module, _)) -> Ok(module)
    Error(e) -> Error(e)
  }
}

// --- Token utilities ---

fn peek(parser: Parser) -> Option(#(Token, Position)) {
  case parser.tokens {
    [tok, ..] -> Some(tok)
    [] -> None
  }
}

fn peek_token(parser: Parser) -> Option(Token) {
  case parser.tokens {
    [#(tok, _), ..] -> Some(tok)
    [] -> None
  }
}

fn advance(parser: Parser) -> #(#(Token, Position), Parser) {
  case parser.tokens {
    [tok, ..rest] -> #(tok, Parser(..parser, tokens: rest))
    [] -> #(#(token.Newline, Position(0)), parser)
  }
}

fn expect(parser: Parser, expected: Token) -> ParseResult(Position) {
  case parser.tokens {
    [#(tok, pos), ..rest] if tok == expected ->
      Ok(#(pos, Parser(..parser, tokens: rest)))
    [#(tok, pos), ..] ->
      Error(error.ParseError(
        pos.line,
        token.token_name(expected),
        token.token_name(tok),
      ))
    [] ->
      Error(error.ParseError(0, token.token_name(expected), "end of file"))
  }
}

fn expect_name(parser: Parser) -> ParseResult(#(String, Int)) {
  case parser.tokens {
    [#(token.Name(name), Position(line)), ..rest] ->
      Ok(#(#(name, line), Parser(..parser, tokens: rest)))
    [#(tok, Position(line)), ..] ->
      Error(error.ParseError(line, "name", token.token_name(tok)))
    [] -> Error(error.ParseError(0, "name", "end of file"))
  }
}

fn skip_newlines(parser: Parser) -> Parser {
  case parser.tokens {
    [#(token.Newline, _), ..rest] ->
      skip_newlines(Parser(..parser, tokens: rest))
    _ -> parser
  }
}

fn skip_delims(parser: Parser) -> Parser {
  case parser.tokens {
    [#(token.Newline, _), ..rest] ->
      skip_delims(Parser(..parser, tokens: rest))
    [#(token.Semi, _), ..rest] ->
      skip_delims(Parser(..parser, tokens: rest))
    _ -> parser
  }
}

fn current_line(parser: Parser) -> Int {
  case parser.tokens {
    [#(_, Position(line)), ..] -> line
    [] -> 0
  }
}

fn push_context(parser: Parser, ctx: FuncContext) -> Parser {
  Parser(..parser, context_stack: [ctx, ..parser.context_stack])
}

fn pop_context(parser: Parser) -> Parser {
  case parser.context_stack {
    [_, ..rest] -> Parser(..parser, context_stack: rest)
    [] -> parser
  }
}

// --- Module parsing ---

fn parse_module(parser: Parser) -> ParseResult(Module) {
  let parser = skip_newlines(parser)
  case parser.tokens {
    [#(token.Module, Position(line)), ..rest] -> {
      let parser = Parser(..parser, tokens: rest)
      let parser = skip_newlines(parser)
      case expect_name(parser) {
        Ok(#(#(name, _), parser)) -> {
          let parser = Parser(..parser, module_name: name)
          let parser = skip_newlines(parser)
          // Check for export before toplevel stmts
          let #(export_decl, parser) = case peek_token(parser) {
            Some(token.Export) -> {
              case parse_export_stmt(parser) {
                Ok(#(export, p)) -> #(Some(export), skip_delims(p))
                Error(_) -> #(None, parser)
              }
            }
            _ -> #(None, parser)
          }
          case parse_toplevel_stmts(parser, []) {
            Ok(#(stmts, parser)) -> {
              let parser = skip_newlines(parser)
              case expect(parser, token.End) {
                Ok(#(_, parser)) -> {
                  let body = case export_decl {
                    Some(e) -> [e, ..stmts]
                    None -> [ast.ExportAllDecl(line: line), ..stmts]
                  }
                  Ok(#(
                    ast.Module(name: name, line: line, body: body),
                    parser,
                  ))
                }
                Error(e) -> Error(e)
              }
            }
            Error(e) -> Error(e)
          }
        }
        Error(e) -> Error(e)
      }
    }
    // Support actor as top-level construct (implicit module)
    [#(token.Actor, Position(line)), ..] -> {
      case parse_class_def(parser, True) {
        Ok(#(class_def, parser)) -> {
          let name = case class_def {
            ast.ClassDef(n, _, _, _) -> n
            _ -> parser.module_name
          }
          Ok(#(
            ast.Module(
              name: name,
              line: line,
              body: [ast.ExportAllDecl(line: line), class_def],
            ),
            parser,
          ))
        }
        Error(e) -> Error(e)
      }
    }
    // Support class as top-level construct (implicit module)
    [#(token.Class, Position(line)), ..] -> {
      // Parse as if it's a module that contains a single class
      case parse_class_def(parser, False) {
        Ok(#(class_def, parser)) -> {
          let name = case class_def {
            ast.ClassDef(n, _, _, _) -> n
            _ -> parser.module_name
          }
          Ok(#(
            ast.Module(
              name: name,
              line: line,
              body: [ast.ExportAllDecl(line: line), class_def],
            ),
            parser,
          ))
        }
        Error(e) -> Error(e)
      }
    }
    [#(tok, Position(line)), ..] ->
      Error(error.ParseError(line, "module", token.token_name(tok)))
    [] -> Error(error.ParseError(0, "module", "end of file"))
  }
}

// --- Top-level statement parsing ---

fn parse_toplevel_stmts(
  parser: Parser,
  acc: List(TopLevel),
) -> ParseResult(List(TopLevel)) {
  let parser = skip_delims(parser)
  case peek_token(parser) {
    Some(token.End) | None -> Ok(#(list.reverse(acc), parser))
    _ ->
      case parse_toplevel_stmt(parser) {
        Ok(#(stmt, parser)) ->
          parse_toplevel_stmts(skip_delims(parser), [stmt, ..acc])
        Error(e) -> Error(e)
      }
  }
}

fn parse_toplevel_stmt(parser: Parser) -> ParseResult(TopLevel) {
  case peek_token(parser) {
    Some(token.Include) -> parse_include_stmt(parser)
    Some(token.Behavior) -> parse_behavior_stmt(parser)
    Some(token.Record) -> parse_record_def(parser)
    Some(token.Patterns) -> parse_patterns_def(parser)
    Some(token.At) -> parse_generic_attr(parser)
    Some(token.Class) -> parse_class_def(parser, False)
    Some(token.Actor) -> parse_class_def(parser, True)
    Some(token.Def) -> parse_method_or_module_method(parser)
    Some(token.Needs) -> parse_needs_decl(parser)
    Some(token.Platform) -> parse_platform_def(parser)
    Some(token.Expose) -> parse_expose_decl(parser)
    Some(token.Peers) -> parse_peers_decl(parser)
    Some(token.Export) -> parse_export_stmt(parser)
    Some(token.ExportAll) -> parse_export_all(parser)
    Some(token.Name(_)) -> parse_decorated_or_method(parser)
    _ ->
      Error(error.ParseError(
        current_line(parser),
        "top-level statement",
        case peek(parser) {
          Some(#(tok, _)) -> token.token_name(tok)
          None -> "end of file"
        },
      ))
  }
}

// --- Needs ---

fn parse_needs_decl(parser: Parser) -> ParseResult(TopLevel) {
  let #(#(_, Position(line)), parser) = advance(parser)
  case peek(parser) {
    Some(#(token.Name(name), _)) -> {
      let #(_, parser) = advance(parser)
      Ok(#(ast.NeedsDecl(name: name, line: line), parser))
    }
    _ ->
      Error(error.ParseError(
        line,
        "effect name after 'needs'",
        case peek(parser) {
          Some(#(tok, _)) -> token.token_name(tok)
          None -> "end of file"
        },
      ))
  }
}

// --- Platform ---

fn parse_platform_def(parser: Parser) -> ParseResult(TopLevel) {
  let #(#(_, Position(line)), parser) = advance(parser)
  case peek(parser) {
    Some(#(token.Name(name), _)) -> {
      let #(_, parser) = advance(parser)
      let parser = skip_delims(parser)
      case parse_provide_clauses(parser, []) {
        Ok(#(providers, parser)) -> {
          let parser = skip_delims(parser)
          case expect(parser, token.End) {
            Ok(#(_, parser)) ->
              Ok(#(
                ast.PlatformDef(
                  name: name,
                  line: line,
                  providers: providers,
                ),
                parser,
              ))
            Error(e) -> Error(e)
          }
        }
        Error(e) -> Error(e)
      }
    }
    _ ->
      Error(error.ParseError(
        line,
        "platform name after 'platform'",
        case peek(parser) {
          Some(#(tok, _)) -> token.token_name(tok)
          None -> "end of file"
        },
      ))
  }
}

fn parse_provide_clauses(
  parser: Parser,
  acc: List(ast.ProvideClause),
) -> ParseResult(List(ast.ProvideClause)) {
  case peek_token(parser) {
    Some(token.Provide) -> {
      let #(#(_, Position(line)), parser) = advance(parser)
      case peek(parser) {
        Some(#(token.Name(need), _)) -> {
          let #(_, parser) = advance(parser)
          case peek_token(parser) {
            Some(token.Name(with_kw)) if with_kw == "with" -> {
              let #(_, parser) = advance(parser)
              case peek(parser) {
                Some(#(token.Name(impl), _)) -> {
                  let #(_, parser) = advance(parser)
                  let clause =
                    ast.ProvideClause(
                      need: need,
                      implementation: impl,
                      line: line,
                    )
                  let parser = skip_delims(parser)
                  parse_provide_clauses(parser, [clause, ..acc])
                }
                _ ->
                  Error(error.ParseError(
                    line,
                    "implementation name after 'with'",
                    case peek(parser) {
                      Some(#(tok, _)) -> token.token_name(tok)
                      None -> "end of file"
                    },
                  ))
              }
            }
            _ ->
              Error(error.ParseError(
                line,
                "'with' after need name",
                case peek(parser) {
                  Some(#(tok, _)) -> token.token_name(tok)
                  None -> "end of file"
                },
              ))
          }
        }
        _ ->
          Error(error.ParseError(
            line,
            "need name after 'provide'",
            case peek(parser) {
              Some(#(tok, _)) -> token.token_name(tok)
              None -> "end of file"
            },
          ))
      }
    }
    _ -> Ok(#(list.reverse(acc), parser))
  }
}

// --- Using clauses ---

fn parse_using_clauses(
  parser: Parser,
  acc: List(ast.UsingOverride),
) -> ParseResult(List(ast.UsingOverride)) {
  // Parse: MockName for NeedName [, MockName2 for NeedName2 ...]
  case peek(parser) {
    Some(#(token.Name(mock), Position(line))) -> {
      let #(_, parser) = advance(parser)
      case peek_token(parser) {
        Some(token.For) -> {
          let #(_, parser) = advance(parser)
          case peek(parser) {
            Some(#(token.Name(need), _)) -> {
              let #(_, parser) = advance(parser)
              let override =
                ast.UsingOverride(mock: mock, need: need, line: line)
              case peek_token(parser) {
                Some(token.Comma) -> {
                  let #(_, parser) = advance(parser)
                  parse_using_clauses(parser, [override, ..acc])
                }
                _ -> Ok(#(list.reverse([override, ..acc]), parser))
              }
            }
            _ ->
              Error(error.ParseError(
                line,
                "need name after 'for'",
                case peek(parser) {
                  Some(#(tok, _)) -> token.token_name(tok)
                  None -> "end of file"
                },
              ))
          }
        }
        _ ->
          Error(error.ParseError(
            line,
            "'for' after mock name",
            case peek(parser) {
              Some(#(tok, _)) -> token.token_name(tok)
              None -> "end of file"
            },
          ))
      }
    }
    _ -> Ok(#(list.reverse(acc), parser))
  }
}

// --- Expose ---

fn parse_expose_decl(parser: Parser) -> ParseResult(TopLevel) {
  let #(#(_, Position(line)), parser) = advance(parser)
  case parse_exposed_methods(parser, []) {
    Ok(#(methods, parser)) ->
      Ok(#(ast.ExposeDecl(methods: methods, line: line), parser))
    Error(e) -> Error(e)
  }
}

fn parse_exposed_methods(
  parser: Parser,
  acc: List(ast.ExposedMethod),
) -> ParseResult(List(ast.ExposedMethod)) {
  case peek(parser) {
    Some(#(token.Name(name), Position(line))) -> {
      let #(_, parser) = advance(parser)
      // Parse optional parenthesized params to determine arity
      let #(arity, parser) = case peek_token(parser) {
        Some(token.LParen) -> {
          let #(_, parser) = advance(parser)
          case peek_token(parser) {
            Some(token.RParen) -> {
              let #(_, parser) = advance(parser)
              #(0, parser)
            }
            _ -> {
              let #(count, parser) = count_params(parser, 1)
              #(count, parser)
            }
          }
        }
        _ -> #(0, parser)
      }
      let method = ast.ExposedMethod(name: name, arity: arity, line: line)
      case peek_token(parser) {
        Some(token.Comma) -> {
          let #(_, parser) = advance(parser)
          let parser = skip_newlines(parser)
          parse_exposed_methods(parser, [method, ..acc])
        }
        _ -> Ok(#(list.reverse([method, ..acc]), parser))
      }
    }
    _ -> Ok(#(list.reverse(acc), parser))
  }
}

fn count_params(parser: Parser, count: Int) -> #(Int, Parser) {
  case peek_token(parser) {
    Some(token.RParen) -> {
      let #(_, parser) = advance(parser)
      #(count, parser)
    }
    Some(token.Comma) -> {
      let #(_, parser) = advance(parser)
      count_params(parser, count + 1)
    }
    _ -> {
      let #(_, parser) = advance(parser)
      count_params(parser, count)
    }
  }
}

// --- Peers ---

fn parse_peers_decl(parser: Parser) -> ParseResult(TopLevel) {
  let #(#(_, Position(line)), parser) = advance(parser)
  case parse_peer_defs(parser, []) {
    Ok(#(peers, parser)) ->
      Ok(#(ast.PeersDecl(peers: peers, line: line), parser))
    Error(e) -> Error(e)
  }
}

fn parse_peer_defs(
  parser: Parser,
  acc: List(ast.PeerDef),
) -> ParseResult(List(ast.PeerDef)) {
  case peek(parser) {
    Some(#(token.Name(name), Position(line))) -> {
      let #(_, parser) = advance(parser)
      case peek_token(parser) {
        Some(token.Colon) -> {
          let #(_, parser) = advance(parser)
          let parser = skip_newlines(parser)
          case peek(parser) {
            Some(#(token.Name(actor_type), _)) -> {
              let #(_, parser) = advance(parser)
              let peer =
                ast.PeerDef(name: name, actor_type: actor_type, line: line)
              case peek_token(parser) {
                Some(token.Comma) -> {
                  let #(_, parser) = advance(parser)
                  let parser = skip_newlines(parser)
                  parse_peer_defs(parser, [peer, ..acc])
                }
                _ -> Ok(#(list.reverse([peer, ..acc]), parser))
              }
            }
            _ ->
              Error(error.ParseError(
                line,
                "actor type name after ':'",
                case peek(parser) {
                  Some(#(tok, _)) -> token.token_name(tok)
                  None -> "end of file"
                },
              ))
          }
        }
        _ ->
          Error(error.ParseError(
            line,
            "':' after peer name",
            case peek(parser) {
              Some(#(tok, _)) -> token.token_name(tok)
              None -> "end of file"
            },
          ))
      }
    }
    _ -> Ok(#(list.reverse(acc), parser))
  }
}

// --- Include ---

fn parse_include_stmt(parser: Parser) -> ParseResult(TopLevel) {
  let #(#(_, Position(line)), parser) = advance(parser)
  case parse_module_names(parser, []) {
    Ok(#(names, parser)) ->
      Ok(#(
        ast.Attribute(
          name: "include",
          line: line,
          args: names,
        ),
        parser,
      ))
    Error(e) -> Error(e)
  }
}

fn parse_module_names(
  parser: Parser,
  acc: List(Expr),
) -> ParseResult(List(Expr)) {
  case expect_name(parser) {
    Ok(#(#(name, line), parser)) -> {
      let atom = ast.AtomLit(value: name, line: line)
      case peek_token(parser) {
        Some(token.Comma) -> {
          let #(_, parser) = advance(parser)
          parse_module_names(parser, [atom, ..acc])
        }
        _ -> Ok(#(list.reverse([atom, ..acc]), parser))
      }
    }
    Error(e) -> Error(e)
  }
}

// --- Behavior ---

fn parse_behavior_stmt(parser: Parser) -> ParseResult(TopLevel) {
  let #(#(_, Position(line)), parser) = advance(parser)
  case expect_name(parser) {
    Ok(#(#(name, _), parser)) ->
      Ok(#(ast.BehaviorDecl(name: name, line: line), parser))
    Error(e) -> Error(e)
  }
}

// --- Record ---

fn parse_record_def(parser: Parser) -> ParseResult(TopLevel) {
  let #(#(_, Position(line)), parser) = advance(parser)
  case expect_name(parser) {
    Ok(#(#(name, _), parser)) -> {
      let parser = skip_newlines(parser)
      case peek_token(parser) {
        Some(token.End) -> {
          let #(_, parser) = advance(parser)
          Ok(#(ast.RecordDef(name: name, line: line, fields: []), parser))
        }
        _ ->
          case parse_record_fields(parser, []) {
            Ok(#(fields, parser)) -> {
              let parser = skip_newlines(parser)
              case expect(parser, token.End) {
                Ok(#(_, parser)) ->
                  Ok(#(
                    ast.RecordDef(name: name, line: line, fields: fields),
                    parser,
                  ))
                Error(e) -> Error(e)
              }
            }
            Error(e) -> Error(e)
          }
      }
    }
    Error(e) -> Error(e)
  }
}

fn parse_record_fields(
  parser: Parser,
  acc: List(Expr),
) -> ParseResult(List(Expr)) {
  case expect_name(parser) {
    Ok(#(#(name, line), parser)) -> {
      let field = case peek_token(parser) {
        Some(token.Equals) -> {
          let #(_, parser) = advance(parser)
          case parse_binop_expr(parser, 0) {
            Ok(#(val, parser)) ->
              Ok(#(ast.RecordField2(name: name, value: val, line: line), parser))
            Error(e) -> Error(e)
          }
        }
        _ -> Ok(#(ast.RecordField1(name: name, line: line), parser))
      }
      case field {
        Ok(#(f, parser)) ->
          case peek_token(parser) {
            Some(token.Comma) -> {
              let #(_, parser) = advance(parser)
              let parser = skip_newlines(parser)
              parse_record_fields(parser, [f, ..acc])
            }
            _ -> Ok(#(list.reverse([f, ..acc]), parser))
          }
        Error(e) -> Error(e)
      }
    }
    Error(e) -> Error(e)
  }
}

// --- Patterns ---

fn parse_patterns_def(parser: Parser) -> ParseResult(TopLevel) {
  let #(#(_, Position(line)), parser) = advance(parser)
  case expect_name(parser) {
    Ok(#(#(name, _), parser)) -> {
      let parser = skip_newlines(parser)
      case parse_patterns_members(parser, []) {
        Ok(#(members, parser)) -> {
          let parser = skip_newlines(parser)
          case expect(parser, token.End) {
            Ok(#(_, parser)) ->
              Ok(#(
                ast.PatternsDef(name: name, line: line, members: members),
                parser,
              ))
            Error(e) -> Error(e)
          }
        }
        Error(e) -> Error(e)
      }
    }
    Error(e) -> Error(e)
  }
}

fn parse_patterns_members(
  parser: Parser,
  acc: List(Expr),
) -> ParseResult(List(Expr)) {
  case parse_binop_expr(parser, 0) {
    Ok(#(expr, parser)) ->
      case peek_token(parser) {
        Some(token.Comma) -> {
          let #(_, parser) = advance(parser)
          let parser = skip_newlines(parser)
          parse_patterns_members(parser, [expr, ..acc])
        }
        _ -> Ok(#(list.reverse([expr, ..acc]), parser))
      }
    Error(e) -> Error(e)
  }
}

// --- Generic attribute: @@name args ---

fn parse_generic_attr(parser: Parser) -> ParseResult(TopLevel) {
  let #(#(_, Position(line)), parser) = advance(parser)
  case expect(parser, token.At) {
    Ok(#(_, parser)) ->
      case expect_name(parser) {
        Ok(#(#(name, _), parser)) ->
          case parse_args_if_present(parser) {
            Ok(#(args, parser)) ->
              Ok(#(ast.Attribute(name: name, line: line, args: args), parser))
            Error(e) -> Error(e)
          }
        Error(e) -> Error(e)
      }
    Error(e) -> Error(e)
  }
}

// --- Export ---

fn parse_export_stmt(parser: Parser) -> ParseResult(TopLevel) {
  let #(#(_, Position(line)), parser) = advance(parser)
  case parse_export_names(parser, []) {
    Ok(#(names, parser)) ->
      Ok(#(ast.ExportDecl(line: line, names: names), parser))
    Error(e) -> Error(e)
  }
}

fn parse_export_names(
  parser: Parser,
  acc: List(Expr),
) -> ParseResult(List(Expr)) {
  case expect_name(parser) {
    Ok(#(#(name, line), parser)) ->
      case expect(parser, token.Slash) {
        Ok(#(_, parser)) ->
          case parser.tokens {
            [#(token.Int(arity), _), ..rest] -> {
              let parser = Parser(..parser, tokens: rest)
              let entry = ast.FunName(name: name, arity: arity, line: line)
              case peek_token(parser) {
                Some(token.Comma) -> {
                  let #(_, parser) = advance(parser)
                  parse_export_names(parser, [entry, ..acc])
                }
                _ -> Ok(#(list.reverse([entry, ..acc]), parser))
              }
            }
            _ ->
              Error(error.ParseError(
                current_line(parser),
                "integer",
                "other",
              ))
          }
        Error(e) -> Error(e)
      }
    Error(e) -> Error(e)
  }
}

fn parse_export_all(parser: Parser) -> ParseResult(TopLevel) {
  let #(#(_, Position(line)), parser) = advance(parser)
  Ok(#(ast.ExportAllDecl(line: line), parser))
}

// --- Class definition ---

fn parse_class_def(parser: Parser, is_actor: Bool) -> ParseResult(TopLevel) {
  let #(#(_, Position(line)), parser) = advance(parser)
  let parser = skip_newlines(parser)
  case expect_name(parser) {
    Ok(#(#(name, _), parser)) -> {
      let parser = skip_newlines(parser)
      case parse_class_body(parser, name, []) {
        Ok(#(stmts, parser)) -> {
          let parser = skip_newlines(parser)
          case expect(parser, token.End) {
            Ok(#(_, parser)) ->
              Ok(#(ast.ClassDef(name: name, line: line, methods: stmts, is_actor: is_actor), parser))
            Error(e) -> Error(e)
          }
        }
        Error(e) -> Error(e)
      }
    }
    Error(e) -> Error(e)
  }
}

fn parse_class_body(
  parser: Parser,
  class_name: String,
  acc: List(TopLevel),
) -> ParseResult(List(TopLevel)) {
  let parser = skip_delims(parser)
  case peek_token(parser) {
    Some(token.End) -> Ok(#(list.reverse(acc), parser))
    Some(token.Include) -> {
      case parse_class_include(parser, class_name) {
        Ok(#(stmt, parser)) ->
          parse_class_body(skip_delims(parser), class_name, [stmt, ..acc])
        Error(e) -> Error(e)
      }
    }
    Some(token.Meta) -> {
      case parse_meta_stmt(parser, class_name) {
        Ok(#(stmt, parser)) ->
          parse_class_body(skip_delims(parser), class_name, [stmt, ..acc])
        Error(e) -> Error(e)
      }
    }
    Some(token.Def) -> {
      case parse_class_method_def(parser, class_name) {
        Ok(#(stmt, parser)) ->
          parse_class_body(skip_delims(parser), class_name, [stmt, ..acc])
        Error(e) -> Error(e)
      }
    }
    Some(token.Name(_)) -> {
      // Could be a decorator (like "test") before a method
      case parse_class_decorated_method(parser, class_name) {
        Ok(#(stmt, parser)) ->
          parse_class_body(skip_delims(parser), class_name, [stmt, ..acc])
        Error(e) -> Error(e)
      }
    }
    Some(token.Expose) -> {
      case parse_expose_decl(parser) {
        Ok(#(stmt, parser)) ->
          parse_class_body(skip_delims(parser), class_name, [stmt, ..acc])
        Error(e) -> Error(e)
      }
    }
    Some(token.Peers) -> {
      case parse_peers_decl(parser) {
        Ok(#(stmt, parser)) ->
          parse_class_body(skip_delims(parser), class_name, [stmt, ..acc])
        Error(e) -> Error(e)
      }
    }
    _ ->
      Error(error.ParseError(
        current_line(parser),
        "class body statement",
        case peek(parser) {
          Some(#(tok, _)) -> token.token_name(tok)
          None -> "end of file"
        },
      ))
  }
}

fn parse_class_include(
  parser: Parser,
  class_name: String,
) -> ParseResult(TopLevel) {
  let #(#(_, Position(line)), parser) = advance(parser)
  case parse_module_names(parser, []) {
    Ok(#(names, parser)) ->
      Ok(#(
        ast.Attribute(
          name: "_" <> class_name <> "_include",
          line: line,
          args: names,
        ),
        parser,
      ))
    Error(e) -> Error(e)
  }
}

fn parse_meta_stmt(
  parser: Parser,
  class_name: String,
) -> ParseResult(TopLevel) {
  let #(#(_, Position(line)), parser) = advance(parser)
  case expect_name(parser) {
    Ok(#(#(meta_name, _), parser)) -> {
      case peek_token(parser) {
        Some(token.ColonColon) -> {
          let #(_, parser) = advance(parser)
          case expect_name(parser) {
            Ok(#(#(meta_name2, _), parser)) ->
              Ok(#(
                ast.Attribute(
                  name: "_" <> class_name <> "_meta",
                  line: line,
                  args: [
                    ast.AtomLit(value: meta_name, line: 0),
                    ast.AtomLit(value: meta_name2, line: 0),
                  ],
                ),
                parser,
              ))
            Error(e) -> Error(e)
          }
        }
        _ ->
          Ok(#(
            ast.Attribute(
              name: "_" <> class_name <> "_meta",
              line: line,
              args: [ast.AtomLit(value: meta_name, line: 0)],
            ),
            parser,
          ))
      }
    }
    Error(e) -> Error(e)
  }
}

fn parse_class_method_def(
  parser: Parser,
  class_name: String,
) -> ParseResult(TopLevel) {
  let #(#(_, Position(line)), parser) = advance(parser)
  // Check if it's a class method (def self.name) or instance method (def name)
  case peek_token(parser) {
    Some(token.SelfDot) -> {
      let #(_, parser) = advance(parser)
      case expect_name(parser) {
        Ok(#(#(method_name, _), parser)) -> {
          let prefixed_name =
            "_"
            <> class_name
            <> "_class_method_"
            <> method_name
          parse_func_def_body(parser, prefixed_name, line, ast.ClassMethod, False)
        }
        Error(e) -> Error(e)
      }
    }
    _ -> {
      case expect_name(parser) {
        Ok(#(#(method_name, _), parser)) -> {
          let prefixed_name =
            "_"
            <> class_name
            <> "_instance_method_"
            <> method_name
          parse_func_def_body(
            parser,
            prefixed_name,
            line,
            ast.InstanceMethod,
            True,
          )
        }
        Error(e) -> Error(e)
      }
    }
  }
}

fn parse_class_decorated_method(
  parser: Parser,
  class_name: String,
) -> ParseResult(TopLevel) {
  case expect_name(parser) {
    Ok(#(#(attr_name, attr_line), parser_after_name)) -> {
      // Optional args for decorator
      let #(attr_args, parser_after_args) = case peek_token(parser_after_name) {
        Some(token.LParen) -> {
          case parse_paren_args(parser_after_name) {
            Ok(#(args, p)) -> #(args, p)
            Error(_) -> #([], parser_after_name)
          }
        }
        _ -> #([], parser_after_name)
      }
      let parser2 = skip_newlines(parser_after_args)
      // Now expect def
      case peek_token(parser2) {
        Some(token.Def) -> {
          case parse_class_method_def(parser2, class_name) {
            Ok(#(func_def, parser3)) -> {
              let func_name_and_arity = get_func_name_arity(func_def)
              let full_args =
                list.append(attr_args, [func_name_and_arity])
              let attr =
                ast.Attribute(
                  name: attr_name,
                  line: attr_line,
                  args: full_args,
                )
              Ok(#(ast.DecoratedFunc(attr: attr, func: func_def), parser3))
            }
            Error(e) -> Error(e)
          }
        }
        _ ->
          Error(error.ParseError(
            current_line(parser2),
            "def after decorator",
            case peek(parser2) {
              Some(#(tok, _)) -> token.token_name(tok)
              None -> "end of file"
            },
          ))
      }
    }
    Error(e) -> Error(e)
  }
}

fn get_func_name_arity(func_def: TopLevel) -> Expr {
  case func_def {
    ast.FuncDef(name, line, args, _, _, _) ->
      ast.TupleLit(
        elems: [
          ast.AtomLit(value: extract_method_name(name), line: line),
          ast.IntLit(value: list.length(args), line: 0),
        ],
        line: line,
      )
    _ -> ast.NilLit(line: 0)
  }
}

fn extract_method_name(prefixed: String) -> String {
  // Find the last occurrence of "_method_" and take what's after it
  do_extract_method_name(prefixed, prefixed)
}

fn do_extract_method_name(s: String, original: String) -> String {
  case find_method_suffix(s) {
    Some(name) -> name
    None -> original
  }
}

fn find_method_suffix(s: String) -> Option(String) {
  case s {
    "_method_" <> rest -> Some(rest)
    _ ->
      case string_drop_first(s) {
        "" -> None
        rest -> find_method_suffix(rest)
      }
  }
}

@external(erlang, "jet_parser_ffi", "string_drop_first")
fn string_drop_first(s: String) -> String

// --- Method/module method parsing ---

fn parse_method_or_module_method(parser: Parser) -> ParseResult(TopLevel) {
  let #(#(_, Position(line)), parser) = advance(parser)
  case peek_token(parser) {
    Some(token.SelfDot) -> {
      let #(_, parser) = advance(parser)
      case expect_name(parser) {
        Ok(#(#(name, _), parser)) ->
          parse_func_def_body(parser, name, line, ast.ModuleMethod, False)
        Error(e) -> Error(e)
      }
    }
    _ -> {
      case expect_name(parser) {
        Ok(#(#(name, _), parser)) ->
          parse_func_def_body(parser, name, line, ast.InstanceMethod, True)
        Error(e) -> Error(e)
      }
    }
  }
}

fn parse_decorated_or_method(parser: Parser) -> ParseResult(TopLevel) {
  // Check if this is a decorator (name [args] newline def ...)
  // or something else
  case expect_name(parser) {
    Ok(#(#(attr_name, attr_line), parser_after_name)) -> {
      // Optional args for decorator
      let #(attr_args, parser_after_args) = case peek_token(parser_after_name) {
        Some(token.LParen) -> {
          case parse_paren_args(parser_after_name) {
            Ok(#(args, p)) -> #(args, p)
            Error(_) -> #([], parser_after_name)
          }
        }
        _ -> #([], parser_after_name)
      }
      let parser_check = skip_newlines(parser_after_args)
      case peek_token(parser_check) {
        Some(token.Def) -> {
          case parse_method_or_module_method(parser_check) {
            Ok(#(func_def, parser)) -> {
              let func_name_and_arity = get_func_name_arity_for_module(func_def)
              let full_args = list.append(attr_args, [func_name_and_arity])
              let attr =
                ast.Attribute(
                  name: attr_name,
                  line: attr_line,
                  args: full_args,
                )
              Ok(#(ast.DecoratedFunc(attr: attr, func: func_def), parser))
            }
            Error(e) -> Error(e)
          }
        }
        _ ->
          Error(error.ParseError(
            attr_line,
            "def after decorator",
            case peek(parser_check) {
              Some(#(tok, _)) -> token.token_name(tok)
              None -> "end of file"
            },
          ))
      }
    }
    Error(e) -> Error(e)
  }
}

fn get_func_name_arity_for_module(func_def: TopLevel) -> Expr {
  case func_def {
    ast.FuncDef(name, line, args, _, _, context) -> {
      let arity = case context {
        ast.InstanceMethod -> list.length(args)
        _ -> list.length(args)
      }
      ast.TupleLit(
        elems: [
          ast.AtomLit(value: name, line: line),
          ast.IntLit(value: arity, line: 0),
        ],
        line: line,
      )
    }
    ast.UsingFunc(inner_func, _) ->
      get_func_name_arity_for_module(inner_func)
    _ -> ast.NilLit(line: 0)
  }
}

// --- Function definition body ---

fn parse_func_def_body(
  parser: Parser,
  name: String,
  line: Int,
  context: FuncContext,
  add_self: Bool,
) -> ParseResult(TopLevel) {
  // Parse args
  case parse_args_if_present(parser) {
    Ok(#(raw_args, parser)) -> {
      let args = case add_self {
        True -> [ast.Var(name: "self", line: 0), ..raw_args]
        False -> raw_args
      }
      // Check for guards
      let #(guards, parser) = case peek_token(parser) {
        Some(token.If) -> {
          let #(_, parser) = advance(parser)
          case parse_guard_exprs(parser) {
            Ok(#(gs, p)) -> #(gs, p)
            Error(_) -> #([], parser)
          }
        }
        _ -> #([], parser)
      }
      // Check for using clauses: def foo() using MockIO for IO
      let #(using_overrides, parser) = case peek_token(parser) {
        Some(token.Using) -> {
          let #(_, parser) = advance(parser)
          case parse_using_clauses(parser, []) {
            Ok(#(overrides, p)) -> #(overrides, p)
            Error(_) -> #([], parser)
          }
        }
        _ -> #([], parser)
      }
      // Skip then/newlines before body
      let parser = case peek_token(parser) {
        Some(token.Then) -> {
          let #(_, p) = advance(parser)
          p
        }
        _ -> parser
      }
      let parser = skip_newlines(parser)
      // Parse body
      let parser = push_context(parser, context)
      case parse_stmts(parser) {
        Ok(#(body, parser)) -> {
          let parser = pop_context(parser)
          let parser = skip_newlines(parser)
          case expect(parser, token.End) {
            Ok(#(_, parser)) -> {
              let func_def =
                ast.FuncDef(
                  name: name,
                  line: line,
                  args: args,
                  guards: guards,
                  body: body,
                  context: context,
                )
              case using_overrides {
                [] -> Ok(#(func_def, parser))
                _ ->
                  Ok(#(
                    ast.UsingFunc(
                      func: func_def,
                      overrides: using_overrides,
                    ),
                    parser,
                  ))
              }
            }
            Error(e) -> Error(e)
          }
        }
        Error(e) -> Error(e)
      }
    }
    Error(e) -> Error(e)
  }
}

fn parse_guard_exprs(parser: Parser) -> ParseResult(List(Expr)) {
  let parser = push_context(parser, ast.GuardContext)
  case parse_binop_expr(parser, 0) {
    Ok(#(expr, parser)) -> {
      let parser = pop_context(parser)
      case peek_token(parser) {
        Some(token.Comma) -> {
          let #(_, parser) = advance(parser)
          case parse_guard_exprs(parser) {
            Ok(#(rest, parser)) -> Ok(#([expr, ..rest], parser))
            Error(e) -> Error(e)
          }
        }
        _ -> Ok(#([expr], parser))
      }
    }
    Error(e) -> Error(e)
  }
}

fn parse_args_if_present(
  parser: Parser,
) -> ParseResult(List(Expr)) {
  case peek_token(parser) {
    Some(token.LParen) -> parse_paren_args(parser)
    _ -> Ok(#([], parser))
  }
}

fn parse_paren_args(parser: Parser) -> ParseResult(List(Expr)) {
  let #(_, parser) = advance(parser)
  let parser = skip_newlines(parser)
  case peek_token(parser) {
    Some(token.RParen) -> {
      let #(_, parser) = advance(parser)
      Ok(#([], parser))
    }
    _ -> {
      case parse_args_pattern(parser, []) {
        Ok(#(args, parser)) -> {
          let parser = skip_newlines(parser)
          case expect(parser, token.RParen) {
            Ok(#(_, parser)) -> Ok(#(args, parser))
            Error(e) -> Error(e)
          }
        }
        Error(e) -> Error(e)
      }
    }
  }
}

fn parse_args_pattern(
  parser: Parser,
  acc: List(Expr),
) -> ParseResult(List(Expr)) {
  case parse_binop_expr(parser, 0) {
    Ok(#(expr, parser)) -> {
      let parser = skip_newlines(parser)
      case peek_token(parser) {
        Some(token.Comma) -> {
          let #(_, parser) = advance(parser)
          let parser = skip_newlines(parser)
          parse_args_pattern(parser, [expr, ..acc])
        }
        _ -> Ok(#(list.reverse([expr, ..acc]), parser))
      }
    }
    Error(e) -> Error(e)
  }
}

// --- Statements ---

fn parse_stmts(parser: Parser) -> ParseResult(List(Expr)) {
  parse_stmts_acc(parser, [])
}

fn parse_stmts_acc(
  parser: Parser,
  acc: List(Expr),
) -> ParseResult(List(Expr)) {
  let parser = skip_delims(parser)
  case peek_token(parser) {
    Some(token.End) | Some(token.Else) | Some(token.Elsif)
    | Some(token.Case) | Some(token.After) | Some(token.RBrace) | None ->
      Ok(#(list.reverse(acc), parser))
    _ ->
      case parse_binop_expr(parser, 0) {
        Ok(#(expr, parser)) -> {
          let parser = skip_delims(parser)
          parse_stmts_acc(parser, [expr, ..acc])
        }
        Error(e) -> Error(e)
      }
  }
}

// --- Expression parsing (Pratt parser) ---

/// Precedence levels (matching parser.yrl):
/// 10  = (right)
/// 20  (unused)
/// 30  and, or, xor, band, bor, bxor, |>, |>>, | (left)
/// 35  not, bnot (right, prefix — tighter than and/or, looser than ==)
/// 40  ==, !=, <, >, <=, >= (nonassoc)
/// 45  .. (left)
/// 50  +, -, ++ (left)
/// 60  **, *, /, floordiv, % (left)
/// 70  ! (right, send)
/// 80  ., :: (left)

fn parse_binop_expr(parser: Parser, min_prec: Int) -> ParseResult(Expr) {
  // Parse prefix/unary
  case peek_token(parser) {
    Some(token.Not) -> {
      let #(#(_, Position(line)), parser) = advance(parser)
      case parse_binop_expr(parser, 35) {
        Ok(#(operand, parser)) ->
          continue_binop(
            parser,
            ast.UnaryOp(op: ast.OpNot, operand: operand, line: line),
            min_prec,
          )
        Error(e) -> Error(e)
      }
    }
    Some(token.Bnot) -> {
      let #(#(_, Position(line)), parser) = advance(parser)
      case parse_binop_expr(parser, 35) {
        Ok(#(operand, parser)) ->
          continue_binop(
            parser,
            ast.UnaryOp(op: ast.OpBnot, operand: operand, line: line),
            min_prec,
          )
        Error(e) -> Error(e)
      }
    }
    Some(token.Minus) -> {
      let #(#(_, Position(line)), parser) = advance(parser)
      case parse_binop_expr(parser, 65) {
        Ok(#(operand, parser)) ->
          continue_binop(
            parser,
            ast.UnaryOp(op: ast.OpNeg, operand: operand, line: line),
            min_prec,
          )
        Error(e) -> Error(e)
      }
    }
    _ -> {
      case parse_expr(parser) {
        Ok(#(left, parser)) -> continue_binop(parser, left, min_prec)
        Error(e) -> Error(e)
      }
    }
  }
}

fn continue_binop(
  parser: Parser,
  left: Expr,
  min_prec: Int,
) -> ParseResult(Expr) {
  case peek(parser) {
    Some(#(tok, Position(line))) -> {
      case get_binop_info(tok) {
        Some(#(op, prec, assoc)) if prec >= min_prec -> {
          let #(_, parser) = advance(parser)
          let next_min = case assoc {
            LeftAssoc -> prec + 1
            RightAssoc -> prec
            NonAssoc -> prec + 1
          }
          case op {
            // Special: method call (dot)
            DotOp -> parse_dot_continuation(parser, left, line, min_prec)
            // Special: :: access
            ColonColonOp ->
              case expect_name(parser) {
                Ok(#(#(key, _), parser)) ->
                  continue_binop(
                    parser,
                    ast.ColonColonAccess(map: left, key: key, line: line),
                    min_prec,
                  )
                Error(e) -> Error(e)
              }
            // Special: = assignment
            AssignOp ->
              case parse_binop_expr(parser, next_min) {
                Ok(#(right, parser)) ->
                  continue_binop(
                    parser,
                    ast.Assign(pattern: left, value: right, line: line),
                    min_prec,
                  )
                Error(e) -> Error(e)
              }
            // Special: ! send
            SendOp ->
              case parse_binop_expr(parser, next_min) {
                Ok(#(right, parser)) ->
                  continue_binop(
                    parser,
                    ast.Send(receiver: left, message: right, line: line),
                    min_prec,
                  )
                Error(e) -> Error(e)
              }
            // Special: .. range
            RangeOp ->
              case parse_binop_expr(parser, next_min) {
                Ok(#(right, parser)) ->
                  continue_binop(
                    parser,
                    ast.Range(from: left, to: right, line: line),
                    min_prec,
                  )
                Error(e) -> Error(e)
              }
            // Special: | pipe
            PipeToOp ->
              case parse_binop_expr(parser, next_min) {
                Ok(#(right, parser)) ->
                  continue_binop(
                    parser,
                    ast.PipeOp(left: left, right: right, line: line),
                    min_prec,
                  )
                Error(e) -> Error(e)
              }
            // Regular binary operator
            RegularBinOp(bin_op) ->
              case parse_binop_expr(parser, next_min) {
                Ok(#(right, parser)) ->
                  continue_binop(
                    parser,
                    ast.BinOp(
                      op: bin_op,
                      left: left,
                      right: right,
                      line: line,
                    ),
                    min_prec,
                  )
                Error(e) -> Error(e)
              }
          }
        }
        _ -> Ok(#(left, parser))
      }
    }
    None -> Ok(#(left, parser))
  }
}

type Assoc {
  LeftAssoc
  RightAssoc
  NonAssoc
}

type OpKind {
  RegularBinOp(BinOperator)
  DotOp
  ColonColonOp
  AssignOp
  SendOp
  RangeOp
  PipeToOp
}

fn get_binop_info(tok: Token) -> Option(#(OpKind, Int, Assoc)) {
  case tok {
    token.Equals -> Some(#(AssignOp, 10, RightAssoc))
    token.And -> Some(#(RegularBinOp(ast.OpAnd), 30, LeftAssoc))
    token.Or -> Some(#(RegularBinOp(ast.OpOr), 30, LeftAssoc))
    token.Xor -> Some(#(RegularBinOp(ast.OpXor), 30, LeftAssoc))
    token.Band -> Some(#(RegularBinOp(ast.OpBand), 30, LeftAssoc))
    token.Bor -> Some(#(RegularBinOp(ast.OpBor), 30, LeftAssoc))
    token.Bxor -> Some(#(RegularBinOp(ast.OpBxor), 30, LeftAssoc))
    token.Pipeline -> Some(#(RegularBinOp(ast.OpAnd), 30, LeftAssoc))
    token.Pipe -> Some(#(PipeToOp, 30, LeftAssoc))
    token.EqEq -> Some(#(RegularBinOp(ast.OpEqEq), 40, NonAssoc))
    token.BangEq -> Some(#(RegularBinOp(ast.OpBangEq), 40, NonAssoc))
    token.Lt -> Some(#(RegularBinOp(ast.OpLt), 40, NonAssoc))
    token.Gt -> Some(#(RegularBinOp(ast.OpGt), 40, NonAssoc))
    token.LtEq -> Some(#(RegularBinOp(ast.OpLtEq), 40, NonAssoc))
    token.GtEq -> Some(#(RegularBinOp(ast.OpGtEq), 40, NonAssoc))
    token.DotDot -> Some(#(RangeOp, 45, LeftAssoc))
    token.Plus -> Some(#(RegularBinOp(ast.OpPlus), 50, LeftAssoc))
    token.Minus -> Some(#(RegularBinOp(ast.OpMinus), 50, LeftAssoc))
    token.PlusPlus -> Some(#(RegularBinOp(ast.OpAppend), 50, LeftAssoc))
    token.Pow -> Some(#(RegularBinOp(ast.OpPow), 60, LeftAssoc))
    token.Star -> Some(#(RegularBinOp(ast.OpTimes), 60, LeftAssoc))
    token.Slash -> Some(#(RegularBinOp(ast.OpDiv), 60, LeftAssoc))
    token.FloorDiv -> Some(#(RegularBinOp(ast.OpFloorDiv), 60, LeftAssoc))
    token.Percent -> Some(#(RegularBinOp(ast.OpPercent), 60, LeftAssoc))
    token.Bang -> Some(#(SendOp, 70, RightAssoc))
    token.Dot -> Some(#(DotOp, 80, LeftAssoc))
    token.ColonColon -> Some(#(ColonColonOp, 80, LeftAssoc))
    token.Bsl -> Some(#(RegularBinOp(ast.OpBsl), 30, LeftAssoc))
    token.Bsr -> Some(#(RegularBinOp(ast.OpBsr), 30, LeftAssoc))
    _ -> None
  }
}

// --- Dot continuation (method calls, function application) ---

fn parse_dot_continuation(
  parser: Parser,
  left: Expr,
  line: Int,
  min_prec: Int,
) -> ParseResult(Expr) {
  case peek_token(parser) {
    Some(token.Name(method_name)) -> {
      let #(_, parser) = advance(parser)
      // Check for args
      case peek_token(parser) {
        Some(token.LParen) -> {
          case parse_paren_args(parser) {
            Ok(#(args, parser)) -> {
              // Check for trailing block
              let #(args_with_block, parser) =
                maybe_trailing_block(parser, args)
              continue_binop(
                parser,
                ast.MethodCall(
                  object: left,
                  method: method_name,
                  args: args_with_block,
                  line: line,
                ),
                min_prec,
              )
            }
            Error(e) -> Error(e)
          }
        }
        Some(token.Do) | Some(token.LBrace) -> {
          let #(args_with_block, parser) = maybe_trailing_block(parser, [])
          continue_binop(
            parser,
            ast.MethodCall(
              object: left,
              method: method_name,
              args: args_with_block,
              line: line,
            ),
            min_prec,
          )
        }
        _ ->
          continue_binop(
            parser,
            ast.MethodCall(
              object: left,
              method: method_name,
              args: [],
              line: line,
            ),
            min_prec,
          )
      }
    }
    // obj.(args) - apply func ref
    Some(token.LParen) -> {
      case parse_paren_args(parser) {
        Ok(#(args, parser)) ->
          continue_binop(
            parser,
            ast.Apply(
              func: ast.FuncRefExpr(expr: left),
              args: args,
              line: line,
            ),
            min_prec,
          )
        Error(e) -> Error(e)
      }
    }
    _ ->
      Error(error.ParseError(
        line,
        "method name or arguments after '.'",
        case peek(parser) {
          Some(#(tok, _)) -> token.token_name(tok)
          None -> "end of file"
        },
      ))
  }
}

// --- Trailing block (do...end or {|...|...}) ---

fn maybe_trailing_block(
  parser: Parser,
  args: List(Expr),
) -> #(List(Expr), Parser) {
  case peek_token(parser) {
    Some(token.Do) -> {
      case parse_block_lambda(parser) {
        Ok(#(lambda, parser)) -> #(list.append(args, [lambda]), parser)
        Error(_) -> #(args, parser)
      }
    }
    Some(token.LBrace) -> {
      // Check if this is a block lambda {|args| body}
      case try_parse_brace_lambda(parser) {
        Ok(#(lambda, parser)) -> #(list.append(args, [lambda]), parser)
        Error(_) -> #(args, parser)
      }
    }
    _ -> #(args, parser)
  }
}

fn parse_block_lambda(parser: Parser) -> ParseResult(Expr) {
  let #(#(_, Position(line)), parser) = advance(parser)
  let parser = skip_newlines(parser)
  // Check for |args|
  case peek_token(parser) {
    Some(token.Pipe) -> {
      let #(_, parser) = advance(parser)
      let parser = skip_newlines(parser)
      case parse_lambda_args(parser) {
        Ok(#(args, parser)) -> {
          // Check for guards
          let #(guards, parser) = case peek_token(parser) {
            Some(token.If) -> {
              let #(_, parser) = advance(parser)
              case parse_guard_exprs(parser) {
                Ok(#(gs, p)) -> #(gs, p)
                Error(_) -> #([], parser)
              }
            }
            _ -> #([], parser)
          }
          // Expect closing |
          let parser = skip_newlines(parser)
          case expect(parser, token.Pipe) {
            Ok(#(_, parser)) -> {
              let parser = skip_newlines(parser)
              let parser = push_context(parser, ast.BlockLambda)
              case parse_stmts(parser) {
                Ok(#(body, parser)) -> {
                  let parser = pop_context(parser)
                  let parser = skip_newlines(parser)
                  case expect(parser, token.End) {
                    Ok(#(_, parser)) ->
                      Ok(#(
                        ast.Lambda(
                          args: args,
                          guards: guards,
                          body: body,
                          line: line,
                        ),
                        parser,
                      ))
                    Error(e) -> Error(e)
                  }
                }
                Error(e) -> Error(e)
              }
            }
            Error(e) -> Error(e)
          }
        }
        Error(e) -> Error(e)
      }
    }
    _ -> {
      // No args lambda: do body end
      let parser = push_context(parser, ast.BlockLambda)
      case parse_stmts(parser) {
        Ok(#(body, parser)) -> {
          let parser = pop_context(parser)
          let parser = skip_newlines(parser)
          case expect(parser, token.End) {
            Ok(#(_, parser)) ->
              Ok(#(ast.Lambda(args: [], guards: [], body: body, line: line), parser))
            Error(e) -> Error(e)
          }
        }
        Error(e) -> Error(e)
      }
    }
  }
}

fn try_parse_brace_lambda(parser: Parser) -> ParseResult(Expr) {
  let #(#(_, Position(line)), parser) = advance(parser)
  let parser = skip_newlines(parser)
  case peek_token(parser) {
    Some(token.Pipe) -> {
      let #(_, parser) = advance(parser)
      let parser = skip_newlines(parser)
      case parse_lambda_args(parser) {
        Ok(#(args, parser)) -> {
          let #(guards, parser) = case peek_token(parser) {
            Some(token.If) -> {
              let #(_, parser) = advance(parser)
              case parse_guard_exprs(parser) {
                Ok(#(gs, p)) -> #(gs, p)
                Error(_) -> #([], parser)
              }
            }
            _ -> #([], parser)
          }
          let parser = skip_newlines(parser)
          case expect(parser, token.Pipe) {
            Ok(#(_, parser)) -> {
              let parser = skip_newlines(parser)
              let parser = push_context(parser, ast.BlockLambda)
              case parse_stmts_until_rbrace(parser) {
                Ok(#(body, parser)) -> {
                  let parser = pop_context(parser)
                  let parser = skip_newlines(parser)
                  case expect(parser, token.RBrace) {
                    Ok(#(_, parser)) ->
                      Ok(#(
                        ast.Lambda(
                          args: args,
                          guards: guards,
                          body: body,
                          line: line,
                        ),
                        parser,
                      ))
                    Error(e) -> Error(e)
                  }
                }
                Error(e) -> Error(e)
              }
            }
            Error(e) -> Error(e)
          }
        }
        Error(e) -> Error(e)
      }
    }
    _ -> Error(error.ParseError(line, "|", "other"))
  }
}

fn parse_stmts_until_rbrace(parser: Parser) -> ParseResult(List(Expr)) {
  parse_stmts_until_rbrace_acc(parser, [])
}

fn parse_stmts_until_rbrace_acc(
  parser: Parser,
  acc: List(Expr),
) -> ParseResult(List(Expr)) {
  let parser = skip_delims(parser)
  case peek_token(parser) {
    Some(token.RBrace) | None -> Ok(#(list.reverse(acc), parser))
    _ ->
      case parse_binop_expr(parser, 0) {
        Ok(#(expr, parser)) ->
          parse_stmts_until_rbrace_acc(skip_delims(parser), [expr, ..acc])
        Error(e) -> Error(e)
      }
  }
}

fn parse_lambda_args(
  parser: Parser,
) -> ParseResult(List(Expr)) {
  parse_lambda_args_acc(parser, [])
}

fn parse_lambda_args_acc(
  parser: Parser,
  acc: List(Expr),
) -> ParseResult(List(Expr)) {
  case peek_token(parser) {
    Some(token.Pipe) | Some(token.If) ->
      Ok(#(list.reverse(acc), parser))
    _ ->
      // Use precedence 31 to prevent | from being consumed as infix op
      case parse_binop_expr(parser, 31) {
        Ok(#(arg, parser)) -> {
          case peek_token(parser) {
            Some(token.Comma) -> {
              let #(_, parser) = advance(parser)
              let parser = skip_newlines(parser)
              parse_lambda_args_acc(parser, [arg, ..acc])
            }
            _ -> Ok(#(list.reverse([arg, ..acc]), parser))
          }
        }
        Error(e) -> Error(e)
      }
  }
}

// --- Primary expressions ---

fn parse_expr(parser: Parser) -> ParseResult(Expr) {
  case peek(parser) {
    Some(#(token.Int(value), Position(line))) -> {
      let #(_, parser) = advance(parser)
      Ok(#(ast.IntLit(value: value, line: line), parser))
    }
    Some(#(token.Float(value), Position(line))) -> {
      let #(_, parser) = advance(parser)
      Ok(#(ast.FloatLit(value: value, line: line), parser))
    }
    Some(#(token.Str(value), Position(line))) -> {
      let #(_, parser) = advance(parser)
      Ok(#(ast.StrLit(value: value, line: line), parser))
    }
    Some(#(token.Atom(value), Position(line))) -> {
      let #(_, parser) = advance(parser)
      Ok(#(ast.AtomLit(value: value, line: line), parser))
    }
    Some(#(token.True, Position(line))) -> {
      let #(_, parser) = advance(parser)
      Ok(#(ast.BoolLit(value: True, line: line), parser))
    }
    Some(#(token.False, Position(line))) -> {
      let #(_, parser) = advance(parser)
      Ok(#(ast.BoolLit(value: False, line: line), parser))
    }
    Some(#(token.Nil, Position(line))) -> {
      let #(_, parser) = advance(parser)
      Ok(#(ast.NilLit(line: line), parser))
    }
    Some(#(token.At, Position(line))) -> {
      let #(_, parser) = advance(parser)
      case expect_name(parser) {
        Ok(#(#(name, _), parser)) ->
          Ok(#(ast.RefAttr(name: name, line: line), parser))
        Error(e) -> Error(e)
      }
    }
    Some(#(token.LParen, _)) -> parse_paren_expr(parser)
    Some(#(token.LBrack, _)) -> parse_list_expr(parser)
    Some(#(token.LBrace, _)) -> parse_brace_expr(parser)
    Some(#(token.BinaryBegin, _)) -> parse_binary_expr(parser)
    Some(#(token.Percent, _)) -> parse_record_expr(parser)
    Some(#(token.If, _)) -> parse_if_expr(parser)
    Some(#(token.Match, _)) -> parse_match_expr(parser)
    Some(#(token.Receive, _)) -> parse_receive_expr(parser)
    Some(#(token.Catch, Position(line))) -> {
      let #(_, parser) = advance(parser)
      case parse_binop_expr(parser, 0) {
        Ok(#(expr, parser)) ->
          Ok(#(ast.CatchExpr(expr: expr, line: line), parser))
        Error(e) -> Error(e)
      }
    }
    Some(#(token.Do, _)) -> {
      case parse_block_lambda(parser) {
        Ok(#(lambda, parser)) -> Ok(#(lambda, parser))
        Error(e) -> Error(e)
      }
    }
    Some(#(token.Amp, _)) -> parse_get_func(parser)
    Some(#(token.SelfDot, Position(line))) -> {
      let #(_, parser) = advance(parser)
      case expect_name(parser) {
        Ok(#(#(method_name, _), parser)) -> {
          case peek_token(parser) {
            Some(token.LParen) -> {
              case parse_paren_args(parser) {
                Ok(#(args, parser)) -> {
                  let #(args_with_block, parser) =
                    maybe_trailing_block(parser, args)
                  Ok(#(
                    ast.MethodCall(
                      object: ast.Var(name: "self", line: line),
                      method: method_name,
                      args: args_with_block,
                      line: line,
                    ),
                    parser,
                  ))
                }
                Error(e) -> Error(e)
              }
            }
            Some(token.Do) | Some(token.LBrace) -> {
              let #(args_with_block, parser) = maybe_trailing_block(parser, [])
              Ok(#(
                ast.MethodCall(
                  object: ast.Var(name: "self", line: line),
                  method: method_name,
                  args: args_with_block,
                  line: line,
                ),
                parser,
              ))
            }
            _ ->
              Ok(#(
                ast.MethodCall(
                  object: ast.Var(name: "self", line: line),
                  method: method_name,
                  args: [],
                  line: line,
                ),
                parser,
              ))
          }
        }
        Error(e) -> Error(e)
      }
    }
    Some(#(token.Name(name), Position(line))) -> parse_name_expr(parser, name, line)
    _ ->
      Error(error.ParseError(
        current_line(parser),
        "expression",
        case peek(parser) {
          Some(#(tok, _)) -> token.token_name(tok)
          None -> "end of file"
        },
      ))
  }
}

// --- Name expression (variable, function call, func_ref) ---

fn parse_name_expr(
  parser: Parser,
  name: String,
  line: Int,
) -> ParseResult(Expr) {
  let #(_, parser) = advance(parser)
  case peek_token(parser) {
    // Module::func or Module::func(args) - function reference
    Some(token.ColonColon) -> {
      let #(_, parser) = advance(parser)
      case peek(parser) {
        Some(#(token.Name(func_name), _)) -> {
          let #(_, parser) = advance(parser)
          let func_ref =
            ast.FuncRef1(module: name, func: func_name, line: line)
          // Check for application
          case peek_token(parser) {
            Some(token.LParen) -> {
              case parse_paren_args(parser) {
                Ok(#(args, parser)) -> {
                  let #(args_with_block, parser) =
                    maybe_trailing_block(parser, args)
                  Ok(#(
                    ast.Apply(func: func_ref, args: args_with_block, line: line),
                    parser,
                  ))
                }
                Error(e) -> Error(e)
              }
            }
            Some(token.Do) | Some(token.LBrace) -> {
              let #(args_with_block, parser) = maybe_trailing_block(parser, [])
              Ok(#(
                ast.Apply(func: func_ref, args: args_with_block, line: line),
                parser,
              ))
            }
            _ -> Ok(#(func_ref, parser))
          }
        }
        Some(#(token.Str(func_name), _)) -> {
          let #(_, parser) = advance(parser)
          let func_ref =
            ast.FuncRefStr(module: name, func: func_name, line: line)
          case peek_token(parser) {
            Some(token.LParen) -> {
              case parse_paren_args(parser) {
                Ok(#(args, parser)) ->
                  Ok(#(ast.Apply(func: func_ref, args: args, line: line), parser))
                Error(e) -> Error(e)
              }
            }
            _ -> Ok(#(func_ref, parser))
          }
        }
        _ ->
          Error(error.ParseError(
            line,
            "function name after ::",
            "other",
          ))
      }
    }
    // name(args) - function application
    Some(token.LParen) -> {
      case parse_paren_args(parser) {
        Ok(#(args, parser)) -> {
          let #(args_with_block, parser) = maybe_trailing_block(parser, args)
          let func_ref = ast.FuncRef0(name: name, line: line)
          Ok(#(
            ast.ApplyName(
              func: func_ref,
              args: args_with_block,
              line: line,
            ),
            parser,
          ))
        }
        Error(e) -> Error(e)
      }
    }
    // name do...end or name {...} - function call with trailing block
    Some(token.Do) -> {
      let #(args_with_block, parser) = maybe_trailing_block(parser, [])
      let func_ref = ast.FuncRef0(name: name, line: line)
      Ok(#(
        ast.ApplyName(func: func_ref, args: args_with_block, line: line),
        parser,
      ))
    }
    _ -> Ok(#(ast.Var(name: name, line: line), parser))
  }
}

// --- Parenthesized expression ---

fn parse_paren_expr(parser: Parser) -> ParseResult(Expr) {
  let #(#(_, Position(line)), parser) = advance(parser)
  let parser = skip_newlines(parser)
  case parse_binop_expr(parser, 0) {
    Ok(#(first, parser)) -> {
      let parser = skip_newlines(parser)
      case peek_token(parser) {
        Some(token.RParen) -> {
          let #(_, parser) = advance(parser)
          Ok(#(first, parser))
        }
        // Comma after first expr -> treat as tuple: (a, b, c)
        Some(token.Comma) -> {
          let #(_, parser) = advance(parser)
          let parser = skip_newlines(parser)
          case parse_comma_exprs(parser) {
            Ok(#(rest, parser)) -> {
              let parser = skip_newlines(parser)
              case expect(parser, token.RParen) {
                Ok(#(_, parser)) ->
                  Ok(#(ast.TupleLit(elems: [first, ..rest], line: line), parser))
                Error(e) -> Error(e)
              }
            }
            Error(e) -> Error(e)
          }
        }
        _ -> Error(error.ParseError(line, ")", "other"))
      }
    }
    Error(e) -> Error(e)
  }
}

fn parse_comma_exprs(parser: Parser) -> ParseResult(List(Expr)) {
  case parse_binop_expr(parser, 0) {
    Ok(#(expr, parser)) -> {
      let parser = skip_newlines(parser)
      case peek_token(parser) {
        Some(token.Comma) -> {
          let #(_, parser) = advance(parser)
          let parser = skip_newlines(parser)
          case parse_comma_exprs(parser) {
            Ok(#(rest, parser)) -> Ok(#([expr, ..rest], parser))
            Error(e) -> Error(e)
          }
        }
        _ -> Ok(#([expr], parser))
      }
    }
    Error(e) -> Error(e)
  }
}

// --- List expression: [elems] or [expr for x in list] ---

fn parse_list_expr(parser: Parser) -> ParseResult(Expr) {
  let #(#(_, Position(line)), parser) = advance(parser)
  let parser = skip_newlines(parser)
  case peek_token(parser) {
    Some(token.RBrack) -> {
      let #(_, parser) = advance(parser)
      Ok(#(ast.NilLit(line: line), parser))
    }
    _ -> {
      // Parse first element
      case parse_binop_expr(parser, 0) {
        Ok(#(first, parser)) -> {
          case peek_token(parser) {
            // List comprehension: [expr for x in list]
            Some(token.For) ->
              parse_list_comprehension(parser, first, line)
            // Cons: [a, b, *rest]
            Some(token.Comma) ->
              parse_list_elems(parser, first, line)
            // Single element list
            _ -> {
              let parser = skip_newlines(parser)
              case expect(parser, token.RBrack) {
                Ok(#(_, parser)) ->
                  Ok(#(
                    ast.Cons(
                      head: first,
                      tail: ast.NilLit(line: line),
                      line: line,
                    ),
                    parser,
                  ))
                Error(e) -> Error(e)
              }
            }
          }
        }
        Error(e) -> Error(e)
      }
    }
  }
}

fn parse_list_elems(
  parser: Parser,
  first: Expr,
  line: Int,
) -> ParseResult(Expr) {
  let #(_, parser) = advance(parser)
  let parser = skip_newlines(parser)
  // Check for splat: *rest
  case peek_token(parser) {
    Some(token.Star) -> {
      let #(_, parser) = advance(parser)
      case parse_binop_expr(parser, 0) {
        Ok(#(rest, parser)) -> {
          let parser = skip_newlines(parser)
          case expect(parser, token.RBrack) {
            Ok(#(_, parser)) ->
              Ok(#(ast.Cons(head: first, tail: rest, line: line), parser))
            Error(e) -> Error(e)
          }
        }
        Error(e) -> Error(e)
      }
    }
    _ -> {
      // Parse at prec 31 to prevent | from being consumed as PipeOp
      case parse_binop_expr(parser, 31) {
        Ok(#(second, parser)) -> {
          case peek_token(parser) {
            Some(token.Comma) -> {
              let #(_, parser) = advance(parser)
              let parser = skip_newlines(parser)
              case peek_token(parser) {
                Some(token.Star) -> {
                  let #(_, parser) = advance(parser)
                  case parse_binop_expr(parser, 0) {
                    Ok(#(rest, parser)) -> {
                      let parser = skip_newlines(parser)
                      case expect(parser, token.RBrack) {
                        Ok(#(_, parser)) ->
                          Ok(#(
                            ast.Cons(
                              head: first,
                              tail: ast.Cons(
                                head: second,
                                tail: rest,
                                line: line,
                              ),
                              line: line,
                            ),
                            parser,
                          ))
                        Error(e) -> Error(e)
                      }
                    }
                    Error(e) -> Error(e)
                  }
                }
                _ -> {
                  case parse_remaining_list_elems(parser, [second, first], line) {
                    Ok(#(expr, parser)) -> Ok(#(expr, parser))
                    Error(e) -> Error(e)
                  }
                }
              }
            }
            // Cons tail: [first, second | tail]
            Some(token.Pipe) -> {
              let #(_, parser) = advance(parser)
              let parser = skip_newlines(parser)
              case parse_binop_expr(parser, 0) {
                Ok(#(tail, parser)) -> {
                  let parser = skip_newlines(parser)
                  case expect(parser, token.RBrack) {
                    Ok(#(_, parser)) ->
                      Ok(#(
                        ast.Cons(
                          head: first,
                          tail: ast.Cons(
                            head: second,
                            tail: tail,
                            line: line,
                          ),
                          line: line,
                        ),
                        parser,
                      ))
                    Error(e) -> Error(e)
                  }
                }
                Error(e) -> Error(e)
              }
            }
            _ -> {
              let parser = skip_newlines(parser)
              case expect(parser, token.RBrack) {
                Ok(#(_, parser)) ->
                  Ok(#(
                    ast.Cons(
                      head: first,
                      tail: ast.Cons(
                        head: second,
                        tail: ast.NilLit(line: line),
                        line: line,
                      ),
                      line: line,
                    ),
                    parser,
                  ))
                Error(e) -> Error(e)
              }
            }
          }
        }
        Error(e) -> Error(e)
      }
    }
  }
}

fn parse_remaining_list_elems(
  parser: Parser,
  acc: List(Expr),
  line: Int,
) -> ParseResult(Expr) {
  // Parse at prec 31 to prevent | from being consumed as PipeOp
  case parse_binop_expr(parser, 31) {
    Ok(#(elem, parser)) -> {
      case peek_token(parser) {
        Some(token.Comma) -> {
          let #(_, parser) = advance(parser)
          let parser = skip_newlines(parser)
          case peek_token(parser) {
            Some(token.Star) -> {
              let #(_, parser) = advance(parser)
              case parse_binop_expr(parser, 0) {
                Ok(#(rest, parser)) -> {
                  let parser = skip_newlines(parser)
                  case expect(parser, token.RBrack) {
                    Ok(#(_, parser)) -> {
                      let all_elems = list.reverse([elem, ..acc])
                      Ok(#(build_cons_with_tail(all_elems, rest, line), parser))
                    }
                    Error(e) -> Error(e)
                  }
                }
                Error(e) -> Error(e)
              }
            }
            _ ->
              parse_remaining_list_elems(parser, [elem, ..acc], line)
          }
        }
        // Cons tail: [..., elem | tail]
        Some(token.Pipe) -> {
          let #(_, parser) = advance(parser)
          let parser = skip_newlines(parser)
          case parse_binop_expr(parser, 0) {
            Ok(#(tail, parser)) -> {
              let parser = skip_newlines(parser)
              case expect(parser, token.RBrack) {
                Ok(#(_, parser)) -> {
                  let all_elems = list.reverse([elem, ..acc])
                  Ok(#(build_cons_with_tail(all_elems, tail, line), parser))
                }
                Error(e) -> Error(e)
              }
            }
            Error(e) -> Error(e)
          }
        }
        _ -> {
          let parser = skip_newlines(parser)
          case expect(parser, token.RBrack) {
            Ok(#(_, parser)) -> {
              let all_elems = list.reverse([elem, ..acc])
              Ok(#(
                build_cons_with_tail(all_elems, ast.NilLit(line: line), line),
                parser,
              ))
            }
            Error(e) -> Error(e)
          }
        }
      }
    }
    Error(e) -> Error(e)
  }
}

fn build_cons_with_tail(elems: List(Expr), tail: Expr, line: Int) -> Expr {
  case elems {
    [] -> tail
    [head, ..rest] ->
      ast.Cons(
        head: head,
        tail: build_cons_with_tail(rest, tail, line),
        line: line,
      )
  }
}

fn parse_list_comprehension(
  parser: Parser,
  template: Expr,
  line: Int,
) -> ParseResult(Expr) {
  case parse_generators(parser, []) {
    Ok(#(generators, parser)) -> {
      // Optional guard - skip newlines before checking for 'if'
      let parser_skip = skip_newlines(parser)
      let #(guard, parser) = case peek_token(parser_skip) {
        Some(token.If) -> {
          let #(_, parser) = advance(parser_skip)
          case parse_binop_expr(parser, 0) {
            Ok(#(g, p)) -> #([g], p)
            Error(_) -> #([], parser_skip)
          }
        }
        _ -> #([], parser_skip)
      }
      let parser = skip_newlines(parser)
      case expect(parser, token.RBrack) {
        Ok(#(_, parser)) ->
          Ok(#(
            ast.ListComp(
              template: template,
              generators: generators,
              guard: guard,
              line: line,
            ),
            parser,
          ))
        Error(e) -> Error(e)
      }
    }
    Error(e) -> Error(e)
  }
}

fn parse_generators(
  parser: Parser,
  acc: List(Expr),
) -> ParseResult(List(Expr)) {
  let parser = skip_newlines(parser)
  case peek_token(parser) {
    Some(token.For) -> {
      let #(#(_, Position(line)), parser) = advance(parser)
      // Parse pattern at precedence 41 to prevent consuming <= (binary generator)
      case parse_binop_expr(parser, 41) {
        Ok(#(pattern, parser)) ->
          case peek_token(parser) {
            Some(token.In) -> {
              let #(_, parser) = advance(parser)
              case parse_binop_expr(parser, 0) {
                Ok(#(body, parser)) -> {
                  let gen =
                    ast.ListGenerator(pattern: pattern, body: body, line: line)
                  parse_generators(parser, [gen, ..acc])
                }
                Error(e) -> Error(e)
              }
            }
            Some(token.LtEq) -> {
              let #(_, parser) = advance(parser)
              case parse_binop_expr(parser, 0) {
                Ok(#(body, parser)) -> {
                  let gen =
                    ast.BinaryGenerator(
                      pattern: pattern,
                      body: body,
                      line: line,
                    )
                  parse_generators(parser, [gen, ..acc])
                }
                Error(e) -> Error(e)
              }
            }
            _ ->
              Error(error.ParseError(
                line,
                "'in' or '<=' in generator",
                "other",
              ))
          }
        Error(e) -> Error(e)
      }
    }
    _ -> Ok(#(list.reverse(acc), parser))
  }
}

// --- Brace expression: tuple or map or brace lambda ---

fn parse_brace_expr(parser: Parser) -> ParseResult(Expr) {
  let #(#(_, Position(line)), parser) = advance(parser)
  let parser = skip_newlines(parser)
  case peek_token(parser) {
    // Empty: {} is empty map
    Some(token.RBrace) -> {
      let #(_, parser) = advance(parser)
      Ok(#(ast.MapExpr(fields: [], line: line), parser))
    }
    // Brace lambda: {|args| body}
    Some(token.Pipe) -> {
      // Backtrack: re-parse as lambda
      parse_brace_lambda_from_pipe(parser, line)
    }
    _ -> {
      // Parse first element, then check if map or tuple
      case parse_binop_expr(parser, 0) {
        Ok(#(first, parser)) -> {
          case peek_token(parser) {
            // Map with fat arrow: {key => value, ...}
            Some(token.FatArrow) -> {
              let #(_, parser) = advance(parser)
              case parse_binop_expr(parser, 0) {
                Ok(#(value, parser)) -> {
                  let field = ast.MapField(key: first, value: value, line: line)
                  parse_remaining_map_fields(parser, [field], line)
                }
                Error(e) -> Error(e)
              }
            }
            // Map with colon: {name: value, ...}
            Some(token.Colon) -> {
              let key_name = case first {
                ast.Var(name, _) -> name
                _ -> "unknown"
              }
              let #(_, parser) = advance(parser)
              let parser = skip_newlines(parser)
              case parse_binop_expr(parser, 0) {
                Ok(#(value, parser)) -> {
                  let field =
                    ast.MapFieldAtom(key: key_name, value: value, line: line)
                  parse_remaining_map_fields(parser, [field], line)
                }
                Error(e) -> Error(e)
              }
            }
            // Tuple: {a, b, c}
            Some(token.Comma) ->
              parse_remaining_tuple_elems(parser, [first], line)
            // Single element tuple
            _ -> {
              let parser = skip_newlines(parser)
              case expect(parser, token.RBrace) {
                Ok(#(_, parser)) ->
                  Ok(#(ast.TupleLit(elems: [first], line: line), parser))
                Error(e) -> Error(e)
              }
            }
          }
        }
        Error(e) -> Error(e)
      }
    }
  }
}

fn parse_brace_lambda_from_pipe(
  parser: Parser,
  line: Int,
) -> ParseResult(Expr) {
  let #(_, parser) = advance(parser)
  let parser = skip_newlines(parser)
  case parse_lambda_args(parser) {
    Ok(#(args, parser)) -> {
      let #(guards, parser) = case peek_token(parser) {
        Some(token.If) -> {
          let #(_, parser) = advance(parser)
          case parse_guard_exprs(parser) {
            Ok(#(gs, p)) -> #(gs, p)
            Error(_) -> #([], parser)
          }
        }
        _ -> #([], parser)
      }
      let parser = skip_newlines(parser)
      case expect(parser, token.Pipe) {
        Ok(#(_, parser)) -> {
          let parser = skip_newlines(parser)
          let parser = push_context(parser, ast.BlockLambda)
          case parse_stmts_until_rbrace(parser) {
            Ok(#(body, parser)) -> {
              let parser = pop_context(parser)
              let parser = skip_newlines(parser)
              case expect(parser, token.RBrace) {
                Ok(#(_, parser)) ->
                  Ok(#(
                    ast.Lambda(
                      args: args,
                      guards: guards,
                      body: body,
                      line: line,
                    ),
                    parser,
                  ))
                Error(e) -> Error(e)
              }
            }
            Error(e) -> Error(e)
          }
        }
        Error(e) -> Error(e)
      }
    }
    Error(e) -> Error(e)
  }
}

fn parse_remaining_map_fields(
  parser: Parser,
  acc: List(Expr),
  line: Int,
) -> ParseResult(Expr) {
  case peek_token(parser) {
    Some(token.Comma) -> {
      let #(_, parser) = advance(parser)
      let parser = skip_newlines(parser)
      case peek_token(parser) {
        Some(token.RBrace) -> {
          let #(_, parser) = advance(parser)
          Ok(#(ast.MapExpr(fields: list.reverse(acc), line: line), parser))
        }
        _ -> {
          case parse_binop_expr(parser, 0) {
            Ok(#(key, parser)) -> {
              case peek_token(parser) {
                Some(token.FatArrow) -> {
                  let #(_, parser) = advance(parser)
                  case parse_binop_expr(parser, 0) {
                    Ok(#(value, parser)) -> {
                      let field =
                        ast.MapField(key: key, value: value, line: line)
                      parse_remaining_map_fields(parser, [field, ..acc], line)
                    }
                    Error(e) -> Error(e)
                  }
                }
                Some(token.Colon) -> {
                  let key_name = case key {
                    ast.Var(name, _) -> name
                    _ -> "unknown"
                  }
                  let #(_, parser) = advance(parser)
                  let parser = skip_newlines(parser)
                  case parse_binop_expr(parser, 0) {
                    Ok(#(value, parser)) -> {
                      let field =
                        ast.MapFieldAtom(
                          key: key_name,
                          value: value,
                          line: line,
                        )
                      parse_remaining_map_fields(parser, [field, ..acc], line)
                    }
                    Error(e) -> Error(e)
                  }
                }
                _ ->
                  Error(error.ParseError(
                    current_line(parser),
                    "=> or :",
                    "other",
                  ))
              }
            }
            Error(e) -> Error(e)
          }
        }
      }
    }
    _ -> {
      let parser = skip_newlines(parser)
      case expect(parser, token.RBrace) {
        Ok(#(_, parser)) ->
          Ok(#(ast.MapExpr(fields: list.reverse(acc), line: line), parser))
        Error(e) -> Error(e)
      }
    }
  }
}

fn parse_remaining_tuple_elems(
  parser: Parser,
  acc: List(Expr),
  line: Int,
) -> ParseResult(Expr) {
  let #(_, parser) = advance(parser)
  let parser = skip_newlines(parser)
  case peek_token(parser) {
    Some(token.RBrace) -> {
      let #(_, parser) = advance(parser)
      Ok(#(ast.TupleLit(elems: list.reverse(acc), line: line), parser))
    }
    _ ->
      case parse_binop_expr(parser, 0) {
        Ok(#(elem, parser)) -> {
          case peek_token(parser) {
            Some(token.Comma) ->
              parse_remaining_tuple_elems(parser, [elem, ..acc], line)
            _ -> {
              let parser = skip_newlines(parser)
              case expect(parser, token.RBrace) {
                Ok(#(_, parser)) ->
                  Ok(#(
                    ast.TupleLit(elems: list.reverse([elem, ..acc]), line: line),
                    parser,
                  ))
                Error(e) -> Error(e)
              }
            }
          }
        }
        Error(e) -> Error(e)
      }
  }
}

// --- Binary expression: <<fields>> ---

fn parse_binary_expr(parser: Parser) -> ParseResult(Expr) {
  let #(#(_, Position(line)), parser) = advance(parser)
  let parser = skip_newlines(parser)
  case peek_token(parser) {
    Some(token.BinaryEnd) -> {
      let #(_, parser) = advance(parser)
      Ok(#(ast.BinaryLit(fields: [], line: line), parser))
    }
    _ ->
      case parse_binary_field(parser) {
        Ok(#(first_field, parser)) -> {
          let parser_skip = skip_newlines(parser)
          case peek_token(parser_skip) {
            // Binary comprehension: << field for x in list >>
            Some(token.For) ->
              parse_binary_comprehension(parser_skip, first_field, line)
            // Regular binary with more fields
            Some(token.Comma) -> {
              let #(_, parser) = advance(parser_skip)
              let parser = skip_newlines(parser)
              case parse_binary_fields(parser, [first_field]) {
                Ok(#(fields, parser)) -> {
                  let parser = skip_newlines(parser)
                  case expect(parser, token.BinaryEnd) {
                    Ok(#(_, parser)) ->
                      Ok(#(ast.BinaryLit(fields: fields, line: line), parser))
                    Error(e) -> Error(e)
                  }
                }
                Error(e) -> Error(e)
              }
            }
            // Single field binary
            _ -> {
              let parser = skip_newlines(parser)
              case expect(parser, token.BinaryEnd) {
                Ok(#(_, parser)) ->
                  Ok(#(
                    ast.BinaryLit(fields: [first_field], line: line),
                    parser,
                  ))
                Error(e) -> Error(e)
              }
            }
          }
        }
        Error(e) -> Error(e)
      }
  }
}

fn parse_binary_comprehension(
  parser: Parser,
  template: Expr,
  line: Int,
) -> ParseResult(Expr) {
  // Unwrap BinaryField1 wrapper — the template should be the raw expression
  // (e.g., BinaryLit) not a binary field
  let unwrapped_template = case template {
    ast.BinaryField1(value) -> value
    other -> other
  }
  case parse_generators(parser, []) {
    Ok(#(generators, parser)) -> {
      let parser_skip = skip_newlines(parser)
      let #(guard, parser) = case peek_token(parser_skip) {
        Some(token.If) -> {
          let #(_, parser) = advance(parser_skip)
          case parse_binop_expr(parser, 0) {
            Ok(#(g, p)) -> #([g], p)
            Error(_) -> #([], parser_skip)
          }
        }
        _ -> #([], parser_skip)
      }
      let parser = skip_newlines(parser)
      case expect(parser, token.BinaryEnd) {
        Ok(#(_, parser)) ->
          Ok(#(
            ast.BinaryComp(
              template: unwrapped_template,
              generators: generators,
              guard: guard,
              line: line,
            ),
            parser,
          ))
        Error(e) -> Error(e)
      }
    }
    Error(e) -> Error(e)
  }
}

fn parse_binary_fields(
  parser: Parser,
  acc: List(Expr),
) -> ParseResult(List(Expr)) {
  case parse_binary_field(parser) {
    Ok(#(field, parser)) ->
      case peek_token(parser) {
        Some(token.Comma) -> {
          let #(_, parser) = advance(parser)
          let parser = skip_newlines(parser)
          parse_binary_fields(parser, [field, ..acc])
        }
        _ -> Ok(#(list.reverse([field, ..acc]), parser))
      }
    Error(e) -> Error(e)
  }
}

fn parse_binary_field(parser: Parser) -> ParseResult(Expr) {
  case parse_binary_value(parser) {
    Ok(#(value, parser)) ->
      case peek_token(parser) {
        Some(token.Colon) -> {
          let #(_, parser) = advance(parser)
          case parse_binary_value(parser) {
            Ok(#(size, parser)) ->
              case peek_token(parser) {
                Some(token.Slash) -> {
                  let #(_, parser) = advance(parser)
                  case parse_binary_types(parser, []) {
                    Ok(#(types, parser)) ->
                      Ok(#(
                        ast.BinaryFieldSizeTypes(
                          value: value,
                          size: size,
                          types: types,
                        ),
                        parser,
                      ))
                    Error(e) -> Error(e)
                  }
                }
                _ ->
                  Ok(#(
                    ast.BinaryFieldSize(
                      value: value,
                      size: size,
                      types_or_default: ast.DefaultTypes,
                    ),
                    parser,
                  ))
              }
            Error(e) -> Error(e)
          }
        }
        Some(token.Slash) -> {
          let #(_, parser) = advance(parser)
          case parse_binary_types(parser, []) {
            Ok(#(types, parser)) ->
              Ok(#(ast.BinaryField2(value: value, types: types), parser))
            Error(e) -> Error(e)
          }
        }
        _ -> Ok(#(ast.BinaryField1(value: value), parser))
      }
    Error(e) -> Error(e)
  }
}

fn parse_binary_value(parser: Parser) -> ParseResult(Expr) {
  case peek(parser) {
    Some(#(token.Int(v), Position(line))) -> {
      let #(_, parser) = advance(parser)
      Ok(#(ast.IntLit(value: v, line: line), parser))
    }
    Some(#(token.Float(v), Position(line))) -> {
      let #(_, parser) = advance(parser)
      Ok(#(ast.FloatLit(value: v, line: line), parser))
    }
    Some(#(token.Atom(v), Position(line))) -> {
      let #(_, parser) = advance(parser)
      Ok(#(ast.AtomLit(value: v, line: line), parser))
    }
    Some(#(token.Str(v), Position(line))) -> {
      let #(_, parser) = advance(parser)
      Ok(#(ast.StrLit(value: v, line: line), parser))
    }
    Some(#(token.Name(v), Position(line))) -> {
      let #(_, parser) = advance(parser)
      Ok(#(ast.Var(name: v, line: line), parser))
    }
    Some(#(token.LParen, _)) -> parse_paren_expr(parser)
    Some(#(token.BinaryBegin, _)) -> parse_binary_expr(parser)
    _ ->
      Error(error.ParseError(
        current_line(parser),
        "binary value",
        "other",
      ))
  }
}

fn parse_binary_types(
  parser: Parser,
  acc: List(Expr),
) -> ParseResult(List(Expr)) {
  case expect_name(parser) {
    Ok(#(#(name, line), parser)) -> {
      let type_atom = ast.AtomLit(value: name, line: line)
      case peek_token(parser) {
        Some(token.Minus) -> {
          let #(_, parser) = advance(parser)
          parse_binary_types(parser, [type_atom, ..acc])
        }
        _ -> Ok(#(list.reverse([type_atom, ..acc]), parser))
      }
    }
    Error(e) -> Error(e)
  }
}

// --- Record expression: %Name(fields) ---

fn parse_record_expr(parser: Parser) -> ParseResult(Expr) {
  let #(#(_, Position(line)), parser) = advance(parser)
  case expect_name(parser) {
    Ok(#(#(name, _), parser)) -> {
      case peek_token(parser) {
        Some(token.Dot) -> {
          // Record field index: %Name.field
          let #(_, parser) = advance(parser)
          case expect_name(parser) {
            Ok(#(#(field, _), parser)) ->
              Ok(#(
                ast.RecordFieldIndex(record: name, field: field, line: line),
                parser,
              ))
            Error(e) -> Error(e)
          }
        }
        Some(token.LParen) -> {
          let #(_, parser) = advance(parser)
          let parser = skip_newlines(parser)
          case peek_token(parser) {
            Some(token.RParen) -> {
              let #(_, parser) = advance(parser)
              Ok(#(ast.RecordExpr(name: name, fields: [], line: line), parser))
            }
            _ ->
              case parse_record_fields(parser, []) {
                Ok(#(fields, parser)) -> {
                  let parser = skip_newlines(parser)
                  case expect(parser, token.RParen) {
                    Ok(#(_, parser)) ->
                      Ok(#(
                        ast.RecordExpr(
                          name: name,
                          fields: fields,
                          line: line,
                        ),
                        parser,
                      ))
                    Error(e) -> Error(e)
                  }
                }
                Error(e) -> Error(e)
              }
          }
        }
        _ ->
          Error(error.ParseError(line, "( or . after record name", "other"))
      }
    }
    Error(e) -> Error(e)
  }
}

// --- If expression ---

fn parse_if_expr(parser: Parser) -> ParseResult(Expr) {
  let #(#(_, Position(line)), parser) = advance(parser)
  case parse_binop_expr(parser, 0) {
    Ok(#(condition, parser)) -> {
      let parser = case peek_token(parser) {
        Some(token.Then) -> {
          let #(_, p) = advance(parser)
          p
        }
        _ -> parser
      }
      let parser = skip_newlines(parser)
      case parse_stmts(parser) {
        Ok(#(then_body, parser)) -> {
          case peek_token(parser) {
            Some(token.Else) -> {
              let #(_, parser) = advance(parser)
              let parser = skip_newlines(parser)
              // "else if" is treated as "elsif"
              case peek_token(parser) {
                Some(token.If) -> {
                  case parse_elsif_expr(parser) {
                    Ok(#(elsif, parser)) ->
                      Ok(#(
                        ast.IfExpr(
                          condition: condition,
                          then_body: then_body,
                          else_body: [elsif],
                          line: line,
                        ),
                        parser,
                      ))
                    Error(e) -> Error(e)
                  }
                }
                _ ->
                  case parse_stmts(parser) {
                    Ok(#(else_body, parser)) -> {
                      let parser = skip_newlines(parser)
                      case expect(parser, token.End) {
                        Ok(#(_, parser)) ->
                          Ok(#(
                            ast.IfExpr(
                              condition: condition,
                              then_body: then_body,
                              else_body: else_body,
                              line: line,
                            ),
                            parser,
                          ))
                        Error(e) -> Error(e)
                      }
                    }
                    Error(e) -> Error(e)
                  }
              }
            }
            Some(token.Elsif) -> {
              case parse_elsif_expr(parser) {
                Ok(#(elsif, parser)) ->
                  Ok(#(
                    ast.IfExpr(
                      condition: condition,
                      then_body: then_body,
                      else_body: [elsif],
                      line: line,
                    ),
                    parser,
                  ))
                Error(e) -> Error(e)
              }
            }
            Some(token.End) -> {
              let #(_, parser) = advance(parser)
              Ok(#(
                ast.IfExpr(
                  condition: condition,
                  then_body: then_body,
                  else_body: [],
                  line: line,
                ),
                parser,
              ))
            }
            _ ->
              Error(error.ParseError(
                current_line(parser),
                "else, elsif, or end",
                "other",
              ))
          }
        }
        Error(e) -> Error(e)
      }
    }
    Error(e) -> Error(e)
  }
}

fn parse_elsif_expr(parser: Parser) -> ParseResult(Expr) {
  let #(#(_, Position(line)), parser) = advance(parser)
  case parse_binop_expr(parser, 0) {
    Ok(#(condition, parser)) -> {
      let parser = case peek_token(parser) {
        Some(token.Then) -> {
          let #(_, p) = advance(parser)
          p
        }
        _ -> parser
      }
      let parser = skip_newlines(parser)
      case parse_stmts(parser) {
        Ok(#(then_body, parser)) -> {
          case peek_token(parser) {
            Some(token.Else) -> {
              let #(_, parser) = advance(parser)
              let parser = skip_newlines(parser)
              case parse_stmts(parser) {
                Ok(#(else_body, parser)) -> {
                  let parser = skip_newlines(parser)
                  case expect(parser, token.End) {
                    Ok(#(_, parser)) ->
                      Ok(#(
                        ast.ElsifExpr(
                          condition: condition,
                          then_body: then_body,
                          else_body: else_body,
                          line: line,
                        ),
                        parser,
                      ))
                    Error(e) -> Error(e)
                  }
                }
                Error(e) -> Error(e)
              }
            }
            Some(token.Elsif) -> {
              case parse_elsif_expr(parser) {
                Ok(#(elsif, parser)) ->
                  Ok(#(
                    ast.ElsifExpr(
                      condition: condition,
                      then_body: then_body,
                      else_body: [elsif],
                      line: line,
                    ),
                    parser,
                  ))
                Error(e) -> Error(e)
              }
            }
            Some(token.End) -> {
              let #(_, parser) = advance(parser)
              Ok(#(
                ast.ElsifExpr(
                  condition: condition,
                  then_body: then_body,
                  else_body: [],
                  line: line,
                ),
                parser,
              ))
            }
            _ ->
              Error(error.ParseError(
                current_line(parser),
                "else, elsif, or end",
                "other",
              ))
          }
        }
        Error(e) -> Error(e)
      }
    }
    Error(e) -> Error(e)
  }
}

// --- Match expression ---

fn parse_match_expr(parser: Parser) -> ParseResult(Expr) {
  let #(#(_, Position(line)), parser) = advance(parser)
  case parse_binop_expr(parser, 0) {
    Ok(#(value, parser)) -> {
      let parser = skip_newlines(parser)
      case parse_case_clauses(parser, []) {
        Ok(#(clauses, parser)) -> {
          let parser = skip_newlines(parser)
          case expect(parser, token.End) {
            Ok(#(_, parser)) ->
              Ok(#(
                ast.MatchExpr(value: value, clauses: clauses, line: line),
                parser,
              ))
            Error(e) -> Error(e)
          }
        }
        Error(e) -> Error(e)
      }
    }
    Error(e) -> Error(e)
  }
}

fn parse_case_clauses(
  parser: Parser,
  acc: List(Expr),
) -> ParseResult(List(Expr)) {
  let parser = skip_delims(parser)
  case peek_token(parser) {
    Some(token.Case) -> {
      case parse_case_clause(parser) {
        Ok(#(clause, parser)) ->
          parse_case_clauses(parser, [clause, ..acc])
        Error(e) -> Error(e)
      }
    }
    _ -> Ok(#(list.reverse(acc), parser))
  }
}

fn parse_case_clause(parser: Parser) -> ParseResult(Expr) {
  let #(_, parser) = advance(parser)
  case parse_pattern_list(parser, []) {
    Ok(#(patterns, parser)) -> {
      // Optional guards
      let #(guards, parser) = case peek_token(parser) {
        Some(token.If) -> {
          let #(_, parser) = advance(parser)
          case parse_guard_exprs(parser) {
            Ok(#(gs, p)) -> #(gs, p)
            Error(_) -> #([], parser)
          }
        }
        _ -> #([], parser)
      }
      let parser = skip_newlines(parser)
      case parse_stmts(parser) {
        Ok(#(body, parser)) ->
          Ok(#(
            ast.CaseClause(patterns: patterns, guards: guards, body: body),
            parser,
          ))
        Error(e) -> Error(e)
      }
    }
    Error(e) -> Error(e)
  }
}

fn parse_pattern_list(
  parser: Parser,
  acc: List(Expr),
) -> ParseResult(List(Expr)) {
  case parse_binop_expr(parser, 0) {
    Ok(#(pattern, parser)) ->
      case peek_token(parser) {
        Some(token.Comma) -> {
          let #(_, parser) = advance(parser)
          let parser = skip_newlines(parser)
          parse_pattern_list(parser, [pattern, ..acc])
        }
        _ -> Ok(#(list.reverse([pattern, ..acc]), parser))
      }
    Error(e) -> Error(e)
  }
}

// --- Receive expression ---

fn parse_receive_expr(parser: Parser) -> ParseResult(Expr) {
  let #(#(_, Position(line)), parser) = advance(parser)
  let parser = skip_newlines(parser)
  case parse_case_clauses(parser, []) {
    Ok(#(clauses, parser)) -> {
      let parser = skip_newlines(parser)
      case peek_token(parser) {
        Some(token.After) -> {
          let #(_, parser) = advance(parser)
          let parser = skip_newlines(parser)
          case parse_expr(parser) {
            Ok(#(timeout_expr, parser)) -> {
              let parser = skip_newlines(parser)
              case parse_stmts(parser) {
                Ok(#(actions, parser)) -> {
                  let parser = skip_newlines(parser)
                  case expect(parser, token.End) {
                    Ok(#(_, parser)) ->
                      Ok(#(
                        ast.ReceiveAfterExpr(
                          clauses: clauses,
                          timeout: timeout_expr,
                          actions: actions,
                          line: line,
                        ),
                        parser,
                      ))
                    Error(e) -> Error(e)
                  }
                }
                Error(e) -> Error(e)
              }
            }
            Error(e) -> Error(e)
          }
        }
        Some(token.End) -> {
          let #(_, parser) = advance(parser)
          Ok(#(ast.ReceiveExpr(clauses: clauses, line: line), parser))
        }
        _ ->
          Error(error.ParseError(
            current_line(parser),
            "after or end",
            "other",
          ))
      }
    }
    Error(e) -> Error(e)
  }
}

// --- Get function: &name/arity or &Module.func/arity ---

fn parse_get_func(parser: Parser) -> ParseResult(Expr) {
  let #(#(_, Position(line)), parser) = advance(parser)
  case expect_name(parser) {
    Ok(#(#(name1, _), parser)) ->
      case peek_token(parser) {
        Some(token.Dot) -> {
          let #(_, parser) = advance(parser)
          case expect_name(parser) {
            Ok(#(#(name2, _), parser)) ->
              case expect(parser, token.Slash) {
                Ok(#(_, parser)) ->
                  case parse_binop_expr(parser, 0) {
                    Ok(#(arity, parser)) ->
                      Ok(#(
                        ast.GetFunc2(
                          module: name1,
                          func: name2,
                          arity: arity,
                          line: line,
                        ),
                        parser,
                      ))
                    Error(e) -> Error(e)
                  }
                Error(e) -> Error(e)
              }
            Error(e) -> Error(e)
          }
        }
        Some(token.Slash) -> {
          let #(_, parser) = advance(parser)
          case parse_binop_expr(parser, 0) {
            Ok(#(arity, parser)) ->
              Ok(#(
                ast.GetFunc1(func: name1, arity: arity, line: line),
                parser,
              ))
            Error(e) -> Error(e)
          }
        }
        _ ->
          Error(error.ParseError(line, ". or / after & name", "other"))
      }
    Error(e) -> Error(e)
  }
}

// --- Parser FFI helper module ---
// We need a small helper for string_drop_first
