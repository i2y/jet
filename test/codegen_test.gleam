import gleeunit

import jet/ast
import jet/codegen/beam

pub fn main() {
  gleeunit.main()
}

pub fn compile_empty_module_test() {
  let module =
    ast.Module(name: "test_empty", line: 1, body: [
      ast.ExportAllDecl(line: 1),
    ])
  let assert Ok(#(_mod, _binary)) = beam.compile(module)
}

pub fn compile_module_with_function_test() {
  let module =
    ast.Module(name: "test_func", line: 1, body: [
      ast.ExportAllDecl(line: 1),
      ast.FuncDef(
        name: "hello",
        line: 2,
        args: [],
        guards: [],
        body: [ast.IntLit(value: 42, line: 3)],
        context: ast.ModuleMethod,
      ),
    ])
  let assert Ok(#(_mod, _binary)) = beam.compile(module)
}
