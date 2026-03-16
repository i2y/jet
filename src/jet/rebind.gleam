/// Variable rebinding pass.
/// Transforms the AST so that rebound variables get unique names,
/// enabling `x = x + 1` style rebinding on BEAM's single-assignment model.
///
/// Version 0 (first binding) keeps the original name.
/// Version N (N >= 1) uses `name@N` as the variable name.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/string
import jet/ast

/// Variable environment: maps variable names to their current version number.
type VarEnv =
  Dict(String, Int)

/// Get the versioned name for a variable.
fn versioned_name(name: String, env: VarEnv) -> String {
  case dict.get(env, name) {
    Ok(0) -> name
    Ok(n) -> name <> "_v" <> int.to_string(n)
    Error(_) -> name
  }
}

/// Convert a version number to a versioned variable name.
fn version_to_name(name: String, version: Int) -> String {
  case version {
    0 -> name
    n -> name <> "_v" <> int.to_string(n)
  }
}

/// Introduce a variable in a pattern. If already bound, increment version.
fn introduce_var(name: String, env: VarEnv) -> #(String, VarEnv) {
  case dict.get(env, name) {
    Ok(n) -> {
      let new_n = n + 1
      #(name <> "_v" <> int.to_string(new_n), dict.insert(env, name, new_n))
    }
    Error(_) -> {
      // First binding - use original name
      #(name, dict.insert(env, name, 0))
    }
  }
}

// --- Public API ---

/// Transform a module, renaming rebound variables in all function bodies.
pub fn rename_module(module: ast.Module) -> ast.Module {
  ast.Module(
    ..module,
    body: list.map(module.body, rename_toplevel),
  )
}

fn rename_toplevel(stmt: ast.TopLevel) -> ast.TopLevel {
  case stmt {
    ast.FuncDef(name, line, args, guards, body, context) -> {
      // Initialize env with variables from function args
      let env = collect_pattern_vars_list(args, dict.new())
      // Mark actor context so @attr uses erlang:put/get
      let env = case context {
        ast.ActorInstanceMethod -> dict.insert(env, "__actor__", -1)
        _ -> env
      }
      // Rename body sequentially
      let #(new_body, final_env) = rename_body(body, env)
      // Auto-append self return for initialize methods
      let new_body = case string.ends_with(name, "_instance_method_initialize") {
        True -> {
          let self_name = versioned_name("self", final_env)
          list.append(new_body, [ast.Var(self_name, line)])
        }
        False -> new_body
      }
      ast.FuncDef(name, line, args, guards, new_body, context)
    }
    ast.ClassDef(name, line, methods, is_actor) -> {
      let is_actor = is_actor || has_meta_actor(methods, name)
      let methods = case is_actor {
        True -> list.map(methods, promote_to_actor_method)
        False -> methods
      }
      ast.ClassDef(name, line, list.map(methods, rename_toplevel), is_actor)
    }
    ast.DecoratedFunc(attr, func) ->
      ast.DecoratedFunc(attr, rename_toplevel(func))
    ast.UsingFunc(func, overrides) ->
      ast.UsingFunc(rename_toplevel(func), overrides)
    _ -> stmt
  }
}

/// Process a list of expressions sequentially, threading the var env.
fn rename_body(
  exprs: List(ast.Expr),
  env: VarEnv,
) -> #(List(ast.Expr), VarEnv) {
  list.fold(exprs, #([], env), fn(acc, expr) {
    let #(renamed_acc, current_env) = acc
    let #(renamed_expr, new_env) = rename_expr_seq(expr, current_env)
    #([renamed_expr, ..renamed_acc], new_env)
  })
  |> fn(result) {
    let #(rev_exprs, env) = result
    #(list.reverse(rev_exprs), env)
  }
}

/// Rename an expression in sequential context (may update env for assignments).
fn rename_expr_seq(
  expr: ast.Expr,
  env: VarEnv,
) -> #(ast.Expr, VarEnv) {
  case expr {
    // @attr = expr  →  desugar based on context:
    //   Actor:  erlang:put(:attr, expr)
    //   Class:  self = setelement(3, self, maps:put(:attr, expr, element(3, self)))
    ast.Assign(ast.RefAttr(attr_name, _), value, line) -> {
      case dict.get(env, "self") {
        Ok(_) -> {
          let new_value = rename_expr(value, env)
          case dict.has_key(env, "__actor__") {
            True -> {
              // Actor: @attr = expr → jet_ffi:actor_put(:attr, expr)
              // Returns the new value (unlike erlang:put which returns old)
              let put_call =
                ast.Apply(
                  ast.FuncRef1("jet_ffi", "actor_put", line),
                  [ast.AtomLit(attr_name, line), new_value],
                  line,
                )
              #(put_call, env)
            }
            False -> {
              // Class: @attr = expr → self = setelement(3, self, maps:put(...))
              let self_name = versioned_name("self", env)
              let self_var = ast.Var(self_name, line)
              let get_state =
                ast.Apply(
                  ast.FuncRef1("erlang", "element", line),
                  [ast.IntLit(3, line), self_var],
                  line,
                )
              let put_attr =
                ast.Apply(
                  ast.FuncRef1("maps", "put", line),
                  [ast.AtomLit(attr_name, line), new_value, get_state],
                  line,
                )
              let new_self =
                ast.Apply(
                  ast.FuncRef1("erlang", "setelement", line),
                  [ast.IntLit(3, line), self_var, put_attr],
                  line,
                )
              let #(new_self_name, new_env) = introduce_var("self", env)
              let new_self_var = ast.Var(new_self_name, line)
              #(ast.Assign(new_self_var, new_self, line), new_env)
            }
          }
        }
        Error(_) -> {
          let new_value = rename_expr(value, env)
          #(ast.Assign(ast.RefAttr(attr_name, line), new_value, line), env)
        }
      }
    }

    ast.Assign(pattern, value, line) -> {
      // First rename the value (RHS) with current env
      let new_value = rename_expr(value, env)
      // Then introduce/rebind variables from the pattern
      let #(new_pattern, new_env) = rename_pattern(pattern, env)
      #(ast.Assign(new_pattern, new_value, line), new_env)
    }
    // Match expression — merge variable envs from all branches
    ast.MatchExpr(value, clauses, line) -> {
      let new_value = rename_expr(value, env)
      let clause_results =
        list.map(clauses, fn(c) { rename_clause_with_env(c, env) })
      let branch_envs = list.map(clause_results, fn(r) { r.1 })
      let max_env = compute_max_env(branch_envs, env)
      let new_clauses =
        list.map(clause_results, fn(r) {
          let #(clause, branch_env) = r
          case clause {
            ast.CaseClause(patterns, guards, body) ->
              ast.CaseClause(
                patterns,
                guards,
                pad_branch_body(body, branch_env, max_env, env, line),
              )
            _ -> clause
          }
        })
      #(ast.MatchExpr(new_value, new_clauses, line), max_env)
    }

    // If expression — merge variable envs from then/else branches
    ast.IfExpr(condition, then_body, else_body, line) -> {
      let new_cond = rename_expr(condition, env)
      let #(new_then, then_env) = rename_body(then_body, env)
      let #(new_else, else_env) = rename_body(else_body, env)
      let max_env = compute_max_env([then_env, else_env], env)
      let padded_then =
        pad_branch_body(new_then, then_env, max_env, env, line)
      let padded_else =
        pad_branch_body(new_else, else_env, max_env, env, line)
      #(ast.IfExpr(new_cond, padded_then, padded_else, line), max_env)
    }

    ast.ElsifExpr(condition, then_body, else_body, line) -> {
      let new_cond = rename_expr(condition, env)
      let #(new_then, then_env) = rename_body(then_body, env)
      let #(new_else, else_env) = rename_body(else_body, env)
      let max_env = compute_max_env([then_env, else_env], env)
      let padded_then =
        pad_branch_body(new_then, then_env, max_env, env, line)
      let padded_else =
        pad_branch_body(new_else, else_env, max_env, env, line)
      #(ast.ElsifExpr(new_cond, padded_then, padded_else, line), max_env)
    }

    // For non-assignment expressions, rename but don't change env
    _ -> #(rename_expr(expr, env), env)
  }
}

/// Rename variable references in an expression (read-only, no env changes).
fn rename_expr(expr: ast.Expr, env: VarEnv) -> ast.Expr {
  case expr {
    // Variable reference - use current version
    ast.Var(name, line) -> ast.Var(versioned_name(name, env), line)

    // Literals - no change
    ast.IntLit(_, _)
    | ast.FloatLit(_, _)
    | ast.StrLit(_, _)
    | ast.AtomLit(_, _)
    | ast.BoolLit(_, _)
    | ast.NilLit(_) -> expr

    // Instance attribute: @name
    //   Actor:  erlang:get(:name)
    //   Class:  maps:get(name, element(3, self))
    ast.RefAttr(name, line) ->
      case dict.get(env, "self") {
        Ok(_) ->
          case dict.has_key(env, "__actor__") {
            True ->
              ast.Apply(
                ast.FuncRef1("erlang", "get", line),
                [ast.AtomLit(name, line)],
                line,
              )
            False -> {
              let self_name = versioned_name("self", env)
              let self_var = ast.Var(self_name, line)
              let get_state =
                ast.Apply(
                  ast.FuncRef1("erlang", "element", line),
                  [ast.IntLit(3, line), self_var],
                  line,
                )
              ast.Apply(
                ast.FuncRef1("maps", "get", line),
                [ast.AtomLit(name, line), get_state],
                line,
              )
            }
          }
        Error(_) -> expr
      }

    // Binary op
    ast.BinOp(op, left, right, line) ->
      ast.BinOp(op, rename_expr(left, env), rename_expr(right, env), line)

    // Unary op
    ast.UnaryOp(op, operand, line) ->
      ast.UnaryOp(op, rename_expr(operand, env), line)

    // Assignment (nested in expression position)
    ast.Assign(pattern, value, line) -> {
      let new_value = rename_expr(value, env)
      let #(new_pattern, _) = rename_pattern(pattern, env)
      ast.Assign(new_pattern, new_value, line)
    }

    // Method call
    ast.MethodCall(object, method, args, line) ->
      ast.MethodCall(
        rename_expr(object, env),
        method,
        list.map(args, fn(a) { rename_expr(a, env) }),
        line,
      )

    // Function application
    ast.Apply(func, args, line) ->
      ast.Apply(
        rename_expr(func, env),
        list.map(args, fn(a) { rename_expr(a, env) }),
        line,
      )

    ast.ApplyName(func, args, line) ->
      ast.ApplyName(
        rename_expr(func, env),
        list.map(args, fn(a) { rename_expr(a, env) }),
        line,
      )

    // Collections
    ast.ListLit(elems, line) ->
      ast.ListLit(list.map(elems, fn(e) { rename_expr(e, env) }), line)

    ast.Cons(head, tail, line) ->
      ast.Cons(rename_expr(head, env), rename_expr(tail, env), line)

    ast.TupleLit(elems, line) ->
      ast.TupleLit(list.map(elems, fn(e) { rename_expr(e, env) }), line)

    ast.MapExpr(fields, line) ->
      ast.MapExpr(list.map(fields, fn(f) { rename_expr(f, env) }), line)

    ast.MapField(key, value, line) ->
      ast.MapField(rename_expr(key, env), rename_expr(value, env), line)

    ast.MapFieldAtom(key, value, line) ->
      ast.MapFieldAtom(key, rename_expr(value, env), line)

    // Binary
    ast.BinaryLit(fields, line) ->
      ast.BinaryLit(list.map(fields, fn(f) { rename_expr(f, env) }), line)

    ast.BinaryField1(value) -> ast.BinaryField1(rename_expr(value, env))
    ast.BinaryField2(value, types) ->
      ast.BinaryField2(rename_expr(value, env), types)
    ast.BinaryFieldSize(value, size, default) ->
      ast.BinaryFieldSize(rename_expr(value, env), rename_expr(size, env), default)
    ast.BinaryFieldSizeTypes(value, size, types) ->
      ast.BinaryFieldSizeTypes(rename_expr(value, env), rename_expr(size, env), types)

    // If expression - branches get their own scope
    ast.IfExpr(condition, then_body, else_body, line) -> {
      let new_cond = rename_expr(condition, env)
      let #(new_then, _) = rename_body(then_body, env)
      let #(new_else, _) = rename_body(else_body, env)
      ast.IfExpr(new_cond, new_then, new_else, line)
    }

    ast.ElsifExpr(condition, then_body, else_body, line) -> {
      let new_cond = rename_expr(condition, env)
      let #(new_then, _) = rename_body(then_body, env)
      let #(new_else, _) = rename_body(else_body, env)
      ast.ElsifExpr(new_cond, new_then, new_else, line)
    }

    // Match expression - each clause gets its own scope
    ast.MatchExpr(value, clauses, line) ->
      ast.MatchExpr(
        rename_expr(value, env),
        list.map(clauses, fn(c) { rename_clause(c, env) }),
        line,
      )

    // Case clause
    ast.CaseClause(_, _, _) ->
      rename_clause(expr, env)

    // Receive
    ast.ReceiveExpr(clauses, line) ->
      ast.ReceiveExpr(
        list.map(clauses, fn(c) { rename_clause(c, env) }),
        line,
      )

    ast.ReceiveAfterExpr(clauses, timeout, actions, line) -> {
      let #(new_actions, _) = rename_body(actions, env)
      ast.ReceiveAfterExpr(
        list.map(clauses, fn(c) { rename_clause(c, env) }),
        rename_expr(timeout, env),
        new_actions,
        line,
      )
    }

    // Lambda - captures current env, args start fresh scope
    ast.Lambda(args, guards, body, line) -> {
      let lambda_env = collect_pattern_vars_list(args, env)
      let #(new_body, _) = rename_body(body, lambda_env)
      ast.Lambda(args, guards, new_body, line)
    }

    // Comprehensions
    ast.ListComp(template, generators, guard, line) -> {
      let #(new_gens, gen_env) = rename_generators(generators, env)
      ast.ListComp(
        rename_expr(template, gen_env),
        new_gens,
        list.map(guard, fn(g) { rename_expr(g, gen_env) }),
        line,
      )
    }

    ast.BinaryComp(template, generators, guard, line) -> {
      let #(new_gens, gen_env) = rename_generators(generators, env)
      ast.BinaryComp(
        rename_expr(template, gen_env),
        new_gens,
        list.map(guard, fn(g) { rename_expr(g, gen_env) }),
        line,
      )
    }

    ast.ListGenerator(pattern, body, line) ->
      ast.ListGenerator(pattern, rename_expr(body, env), line)

    ast.BinaryGenerator(pattern, body, line) ->
      ast.BinaryGenerator(pattern, rename_expr(body, env), line)

    // Range
    ast.Range(from, to, line) ->
      ast.Range(rename_expr(from, env), rename_expr(to, env), line)

    // ColonColon access
    ast.ColonColonAccess(map_expr, key, line) ->
      ast.ColonColonAccess(rename_expr(map_expr, env), key, line)

    // Pipe
    ast.PipeOp(left, right, line) ->
      ast.PipeOp(rename_expr(left, env), rename_expr(right, env), line)

    // Send
    ast.Send(receiver, message, line) ->
      ast.Send(rename_expr(receiver, env), rename_expr(message, env), line)

    // Catch
    ast.CatchExpr(inner, line) ->
      ast.CatchExpr(rename_expr(inner, env), line)

    // Record expressions
    ast.RecordExpr(name, fields, line) ->
      ast.RecordExpr(
        name,
        list.map(fields, fn(f) { rename_expr(f, env) }),
        line,
      )

    ast.RecordField1(_, _) -> expr
    ast.RecordField2(name, value, line) ->
      ast.RecordField2(name, rename_expr(value, env), line)
    ast.RecordFieldIndex(_, _, _) -> expr

    // Function references - no variables to rename
    ast.FuncRef0(_, _) -> expr
    ast.FuncRef1(_, _, _) -> expr
    ast.FuncRefStr(_, _, _) -> expr
    ast.FuncRefTuple(tuple_expr, func, line) ->
      ast.FuncRefTuple(rename_expr(tuple_expr, env), func, line)
    ast.FuncRefExpr(inner) -> ast.FuncRefExpr(rename_expr(inner, env))

    // Get function
    ast.GetFunc1(_, _, _) -> expr
    ast.GetFunc2(_, _, _, _) -> expr

    // Fun name
    ast.FunName(_, _, _) -> expr
  }
}

/// Rename a case clause: introduce pattern vars into a fresh scope, then rename body.
fn rename_clause(clause: ast.Expr, env: VarEnv) -> ast.Expr {
  case clause {
    ast.CaseClause(patterns, guards, body) -> {
      let clause_env = collect_pattern_vars_list(patterns, env)
      let #(new_body, _) = rename_body(body, clause_env)
      ast.CaseClause(
        patterns,
        list.map(guards, fn(g) { rename_expr(g, clause_env) }),
        new_body,
      )
    }
    _ -> rename_expr(clause, env)
  }
}

/// Rename a pattern, introducing new version for rebound variables.
fn rename_pattern(
  pattern: ast.Expr,
  env: VarEnv,
) -> #(ast.Expr, VarEnv) {
  case pattern {
    ast.Var(name, line) -> {
      let #(new_name, new_env) = introduce_var(name, env)
      #(ast.Var(new_name, line), new_env)
    }

    ast.ListLit(elems, line) -> {
      let #(new_elems, new_env) = rename_pattern_list(elems, env)
      #(ast.ListLit(new_elems, line), new_env)
    }

    ast.Cons(head, tail, line) -> {
      let #(new_head, env1) = rename_pattern(head, env)
      let #(new_tail, env2) = rename_pattern(tail, env1)
      #(ast.Cons(new_head, new_tail, line), env2)
    }

    ast.TupleLit(elems, line) -> {
      let #(new_elems, new_env) = rename_pattern_list(elems, env)
      #(ast.TupleLit(new_elems, line), new_env)
    }

    ast.MapExpr(fields, line) -> {
      let #(new_fields, new_env) = rename_pattern_list(fields, env)
      #(ast.MapExpr(new_fields, line), new_env)
    }

    ast.MapField(key, value, line) -> {
      let #(new_value, new_env) = rename_pattern(value, env)
      #(ast.MapField(key, new_value, line), new_env)
    }

    ast.MapFieldAtom(key, value, line) -> {
      let #(new_value, new_env) = rename_pattern(value, env)
      #(ast.MapFieldAtom(key, new_value, line), new_env)
    }

    ast.BinaryLit(fields, line) -> {
      let #(new_fields, new_env) = rename_pattern_list(fields, env)
      #(ast.BinaryLit(new_fields, line), new_env)
    }

    ast.BinaryField1(value) -> {
      let #(new_value, new_env) = rename_pattern(value, env)
      #(ast.BinaryField1(new_value), new_env)
    }

    ast.BinaryField2(value, types) -> {
      let #(new_value, new_env) = rename_pattern(value, env)
      #(ast.BinaryField2(new_value, types), new_env)
    }

    ast.BinaryFieldSize(value, size, default) -> {
      let #(new_value, new_env) = rename_pattern(value, env)
      #(ast.BinaryFieldSize(new_value, size, default), new_env)
    }

    ast.BinaryFieldSizeTypes(value, size, types) -> {
      let #(new_value, new_env) = rename_pattern(value, env)
      #(ast.BinaryFieldSizeTypes(new_value, size, types), new_env)
    }

    ast.RecordExpr(name, fields, line) -> {
      let #(new_fields, new_env) = rename_pattern_list(fields, env)
      #(ast.RecordExpr(name, new_fields, line), new_env)
    }

    ast.RecordField2(name, value, line) -> {
      let #(new_value, new_env) = rename_pattern(value, env)
      #(ast.RecordField2(name, new_value, line), new_env)
    }

    // Literals and non-variable patterns pass through unchanged
    _ -> #(pattern, env)
  }
}

/// Rename a list of patterns sequentially, threading env.
fn rename_pattern_list(
  patterns: List(ast.Expr),
  env: VarEnv,
) -> #(List(ast.Expr), VarEnv) {
  list.fold(patterns, #([], env), fn(acc, pat) {
    let #(renamed_acc, current_env) = acc
    let #(renamed_pat, new_env) = rename_pattern(pat, current_env)
    #([renamed_pat, ..renamed_acc], new_env)
  })
  |> fn(result) {
    let #(rev_pats, env) = result
    #(list.reverse(rev_pats), env)
  }
}

/// Collect variable names from patterns into the env (at version 0, for initial binding).
fn collect_pattern_vars_list(
  patterns: List(ast.Expr),
  env: VarEnv,
) -> VarEnv {
  list.fold(patterns, env, collect_pattern_vars)
}

fn collect_pattern_vars(env: VarEnv, pattern: ast.Expr) -> VarEnv {
  case pattern {
    ast.Var(name, _) ->
      case dict.has_key(env, name) {
        True -> env
        False -> dict.insert(env, name, 0)
      }
    ast.ListLit(elems, _) -> list.fold(elems, env, collect_pattern_vars)
    ast.Cons(head, tail, _) ->
      collect_pattern_vars(collect_pattern_vars(env, head), tail)
    ast.TupleLit(elems, _) -> list.fold(elems, env, collect_pattern_vars)
    ast.MapExpr(fields, _) -> list.fold(fields, env, collect_pattern_vars)
    ast.MapField(_, value, _) -> collect_pattern_vars(env, value)
    ast.MapFieldAtom(_, value, _) -> collect_pattern_vars(env, value)
    ast.BinaryLit(fields, _) -> list.fold(fields, env, collect_pattern_vars)
    ast.BinaryField1(value) -> collect_pattern_vars(env, value)
    ast.BinaryField2(value, _) -> collect_pattern_vars(env, value)
    ast.BinaryFieldSize(value, _, _) -> collect_pattern_vars(env, value)
    ast.BinaryFieldSizeTypes(value, _, _) -> collect_pattern_vars(env, value)
    ast.RecordExpr(_, fields, _) -> list.fold(fields, env, collect_pattern_vars)
    ast.RecordField2(_, value, _) -> collect_pattern_vars(env, value)
    _ -> env
  }
}

/// Check if a class body contains `meta Actor`.
fn has_meta_actor(methods: List(ast.TopLevel), class_name: String) -> Bool {
  let meta_key = "_" <> class_name <> "_meta"
  list.any(methods, fn(m) {
    case m {
      ast.Attribute(name, _, args) ->
        name == meta_key
        && list.any(args, fn(a) {
          case a {
            ast.AtomLit("Actor", _) -> True
            _ -> False
          }
        })
      _ -> False
    }
  })
}

/// Promote InstanceMethod to ActorInstanceMethod in a toplevel item.
fn promote_to_actor_method(stmt: ast.TopLevel) -> ast.TopLevel {
  case stmt {
    ast.FuncDef(name, line, args, guards, body, ast.InstanceMethod) ->
      ast.FuncDef(name, line, args, guards, body, ast.ActorInstanceMethod)
    ast.DecoratedFunc(attr, func) ->
      ast.DecoratedFunc(attr, promote_to_actor_method(func))
    ast.UsingFunc(func, overrides) ->
      ast.UsingFunc(promote_to_actor_method(func), overrides)
    _ -> stmt
  }
}

/// Rename a clause and return the body's updated env.
fn rename_clause_with_env(
  clause: ast.Expr,
  env: VarEnv,
) -> #(ast.Expr, VarEnv) {
  case clause {
    ast.CaseClause(patterns, guards, body) -> {
      let clause_env = collect_pattern_vars_list(patterns, env)
      let #(new_body, final_env) = rename_body(body, clause_env)
      #(
        ast.CaseClause(
          patterns,
          list.map(guards, fn(g) { rename_expr(g, clause_env) }),
          new_body,
        ),
        final_env,
      )
    }
    _ -> #(rename_expr(clause, env), env)
  }
}

/// Compute the max version for each variable across branch envs.
/// Only considers variables that exist in the input env.
fn compute_max_env(branch_envs: List(VarEnv), input_env: VarEnv) -> VarEnv {
  list.fold(branch_envs, input_env, fn(max_env, branch_env) {
    dict.fold(branch_env, max_env, fn(acc, name, version) {
      case dict.get(input_env, name) {
        Ok(_) -> {
          case dict.get(acc, name) {
            Ok(current_max) ->
              case version > current_max {
                True -> dict.insert(acc, name, version)
                False -> acc
              }
            Error(_) -> dict.insert(acc, name, version)
          }
        }
        Error(_) -> acc
      }
    })
  })
}

/// Pad a branch body with assignments to bring variables up to max versions.
/// For each variable where the branch version < max version, adds:
///   var_vMAX = var_vBRANCH
fn pad_branch_body(
  body: List(ast.Expr),
  branch_env: VarEnv,
  max_env: VarEnv,
  input_env: VarEnv,
  line: Int,
) -> List(ast.Expr) {
  let padding =
    dict.fold(max_env, [], fn(acc, name, max_version) {
      case dict.get(input_env, name) {
        Ok(_) -> {
          let branch_version = case dict.get(branch_env, name) {
            Ok(v) -> v
            Error(_) -> 0
          }
          case max_version > branch_version {
            True -> {
              let src = version_to_name(name, branch_version)
              let dst = version_to_name(name, max_version)
              [
                ast.Assign(
                  ast.Var(dst, line),
                  ast.Var(src, line),
                  line,
                ),
                ..acc
              ]
            }
            False -> acc
          }
        }
        Error(_) -> acc
      }
    })
  list.append(body, padding)
}

/// Rename generators in comprehensions.
fn rename_generators(
  generators: List(ast.Expr),
  env: VarEnv,
) -> #(List(ast.Expr), VarEnv) {
  list.fold(generators, #([], env), fn(acc, gen) {
    let #(renamed_acc, current_env) = acc
    case gen {
      ast.ListGenerator(pattern, body, line) -> {
        let new_body = rename_expr(body, current_env)
        let gen_env = collect_pattern_vars(current_env, pattern)
        #(
          [ast.ListGenerator(pattern, new_body, line), ..renamed_acc],
          gen_env,
        )
      }
      ast.BinaryGenerator(pattern, body, line) -> {
        let new_body = rename_expr(body, current_env)
        let gen_env = collect_pattern_vars(current_env, pattern)
        #(
          [ast.BinaryGenerator(pattern, new_body, line), ..renamed_acc],
          gen_env,
        )
      }
      _ -> #([rename_expr(gen, current_env), ..renamed_acc], current_env)
    }
  })
  |> fn(result) {
    let #(rev_gens, env) = result
    #(list.reverse(rev_gens), env)
  }
}
