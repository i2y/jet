import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import jet/codegen/beam
import jet/error
import jet/lexer
import jet/parser
import jet/rebind
import jet/token_filter
import simplifile

pub fn run(args: List(String)) -> Nil {
  setup_code_paths()
  case parse_cli_args(args) {
    Compile(file_path) -> compile_file(file_path)
    CompileAndRun(file_path, module_func) ->
      compile_and_run(file_path, module_func)
    Build(dir, output_dir) -> build_directory(dir, output_dir)
    Escript(app_module, dir, output) -> build_escript(app_module, dir, output)
    Release(app_module, dir, output) -> build_release(app_module, dir, output)
    Help -> print_usage()
    BadArgs(msg) -> {
      io.println("Error: " <> msg)
      print_usage()
    }
  }
}

type Command {
  Compile(path: String)
  CompileAndRun(path: String, module_func: String)
  Build(dir: String, output_dir: Option(String))
  Escript(app_module: String, dir: String, output: Option(String))
  Release(app_module: String, dir: String, output: Option(String))
  Help
  BadArgs(message: String)
}

fn parse_cli_args(args: List(String)) -> Command {
  case args {
    ["-r", module_func, file_path] -> CompileAndRun(file_path, module_func)
    ["--help"] -> Help
    ["-h"] -> Help
    // build command
    ["build"] -> Build(".", None)
    ["build", "-o", out, dir] -> Build(dir, Some(out))
    ["build", dir] -> Build(dir, None)
    // escript command
    ["escript", "-o", out, app] -> Escript(app, ".", Some(out))
    ["escript", "-o", out, app, dir] -> Escript(app, dir, Some(out))
    ["escript", app, dir] -> Escript(app, dir, None)
    ["escript", app] -> Escript(app, ".", None)
    // release command
    ["release", "-o", out, app] -> Release(app, ".", Some(out))
    ["release", "-o", out, app, dir] -> Release(app, dir, Some(out))
    ["release", app, dir] -> Release(app, dir, None)
    ["release", app] -> Release(app, ".", None)
    // single file compile
    [file_path] -> Compile(file_path)
    [] -> BadArgs("No input file specified")
    _ -> BadArgs("Unknown arguments")
  }
}

fn compile_file(file_path: String) -> Nil {
  case do_compile(file_path) {
    Ok(#(module_name, binary)) -> {
      let beam_path = compute_beam_path(file_path, module_name)
      case write_beam(beam_path, binary) {
        Ok(_) -> Nil
        Error(reason) -> {
          io.println("Error writing .beam file: " <> reason)
          halt(1)
        }
      }
    }
    Error(e) -> {
      io.println(error.format(e))
      halt(1)
    }
  }
}

fn compile_and_run(file_path: String, module_func: String) -> Nil {
  case do_compile(file_path) {
    Ok(#(module_name, binary)) -> {
      let beam_path = compute_beam_path(file_path, module_name)
      case write_beam(beam_path, binary) {
        Ok(_) -> {
          // Add the beam file's directory to code path
          let beam_dir = case string.split(beam_path, "/") {
            [_single] -> "."
            parts -> {
              let dir_parts = list.take(parts, list.length(parts) - 1)
              string.join(dir_parts, "/")
            }
          }
          add_code_path(beam_dir)
          // Parse Module::func
          case string.split(module_func, "::") {
            [mod_name, func_name] -> {
              call_module_func(mod_name, func_name)
            }
            _ -> {
              io.println("Error: expected Module::func format")
              halt(1)
            }
          }
        }
        Error(reason) -> {
          io.println("Error writing .beam file: " <> reason)
          halt(1)
        }
      }
    }
    Error(e) -> {
      io.println(error.format(e))
      halt(1)
    }
  }
}

// --- Build command ---

fn build_directory(dir: String, output_dir: Option(String)) -> Nil {
  case find_jet_files(dir) {
    Ok(files) -> {
      case files {
        [] -> {
          io.println("No .jet files found in " <> dir)
          Nil
        }
        _ -> {
          io.println(
            "Building "
            <> int.to_string(list.length(files))
            <> " files in "
            <> dir
            <> " ...",
          )
          let results = list.map(files, fn(file) { compile_one(file, output_dir) })
          let ok_count = list.count(results, result.is_ok)
          let err_count = list.count(results, fn(r) { !result.is_ok(r) })
          io.println(
            "Build complete: "
            <> int.to_string(ok_count)
            <> " compiled, "
            <> int.to_string(err_count)
            <> " errors",
          )
          case err_count > 0 {
            True -> halt(1)
            False -> Nil
          }
        }
      }
    }
    Error(reason) -> {
      io.println("Error reading directory: " <> reason)
      halt(1)
    }
  }
}

fn compile_one(
  file_path: String,
  output_dir: Option(String),
) -> Result(String, String) {
  case do_compile(file_path) {
    Ok(#(module_name, binary)) -> {
      let beam_path = case output_dir {
        Some(out) -> out <> "/" <> module_name <> ".beam"
        None -> compute_beam_path(file_path, module_name)
      }
      case write_beam(beam_path, binary) {
        Ok(_) -> {
          io.println("  Compiled " <> file_path)
          Ok(module_name)
        }
        Error(reason) -> {
          io.println("  Error writing " <> beam_path <> ": " <> reason)
          Error(file_path)
        }
      }
    }
    Error(e) -> {
      io.println("  Error: " <> file_path <> ": " <> error.format(e))
      Error(file_path)
    }
  }
}

fn find_jet_files(dir: String) -> Result(List(String), String) {
  case simplifile.get_files(dir) {
    Ok(files) -> {
      let jet_files =
        files
        |> list.filter(fn(f) { string.ends_with(f, ".jet") })
        |> list.sort(string.compare)
      Ok(jet_files)
    }
    Error(_) -> Error("Could not read directory: " <> dir)
  }
}

// --- Escript command ---

fn build_escript(
  app_module: String,
  dir: String,
  output: Option(String),
) -> Nil {
  // First build all .jet files
  build_directory(dir, None)

  let output_path = case output {
    Some(p) -> p
    None -> string.lowercase(app_module)
  }

  let stdlib_dir = get_stdlib_beam_dir()

  // Collect beam directories: user dir + stdlib + stdlib subdirs
  let beam_dirs = collect_beam_dirs(dir, stdlib_dir)

  case do_build_escript(app_module, beam_dirs, output_path) {
    Ok(_) -> io.println("Built escript: " <> output_path)
    Error(reason) -> {
      io.println("Error building escript: " <> reason)
      halt(1)
    }
  }
}

fn collect_beam_dirs(user_dir: String, stdlib_dir: String) -> List(String) {
  let base = [user_dir, stdlib_dir]
  // Add subdirectories of stdlib (jet_orchestra, symphony, etc.)
  case simplifile.read_directory(stdlib_dir) {
    Ok(entries) -> {
      let subdirs =
        entries
        |> list.filter_map(fn(entry) {
          let path = stdlib_dir <> "/" <> entry
          case simplifile.is_directory(path) {
            Ok(True) -> Ok(path)
            _ -> Error(Nil)
          }
        })
      list.append(base, subdirs)
    }
    Error(_) -> base
  }
}

// --- Release command ---

fn build_release(
  app_module: String,
  dir: String,
  output: Option(String),
) -> Nil {
  // First build all .jet files
  build_directory(dir, None)

  let output_dir = case output {
    Some(d) -> d
    None -> "_release"
  }

  let stdlib_dir = get_stdlib_beam_dir()
  let beam_dirs = collect_beam_dirs(dir, stdlib_dir)

  case do_build_release(app_module, beam_dirs, output_dir) {
    Ok(_) -> io.println("Built release in: " <> output_dir <> "/")
    Error(reason) -> {
      io.println("Error building release: " <> reason)
      halt(1)
    }
  }
}

// --- Common helpers ---

fn do_compile(
  file_path: String,
) -> Result(#(String, BitArray), error.JetError) {
  let module_name = extract_module_name(file_path)
  case simplifile.read(file_path) {
    Ok(source) -> {
      case lexer.lex(source) {
        Ok(tokens) -> {
          let filtered = token_filter.filter(tokens, module_name)
          case parser.parse(filtered, module_name) {
            Ok(module) -> {
              let module = rebind.rename_module(module)
              case beam.compile(module) {
                Ok(#(_mod_atom, binary)) -> Ok(#(module_name, binary))
                Error(e) -> Error(e)
              }
            }
            Error(e) -> Error(e)
          }
        }
        Error(e) -> Error(e)
      }
    }
    Error(_) ->
      Error(error.FileError(file_path, "Could not read file"))
  }
}

fn extract_module_name(file_path: String) -> String {
  file_path
  |> string.split("/")
  |> list.last()
  |> result.unwrap("unknown")
  |> string.replace(".jet", "")
}

fn compute_beam_path(file_path: String, module_name: String) -> String {
  let dir = case string.split(file_path, "/") {
    [_single] -> "."
    parts -> {
      let dir_parts = list.take(parts, list.length(parts) - 1)
      string.join(dir_parts, "/")
    }
  }
  dir <> "/" <> module_name <> ".beam"
}

fn print_usage() -> Nil {
  io.println("Usage: jet <command> [options] [args]")
  io.println("")
  io.println("Commands:")
  io.println("  <file.jet>                    Compile a single .jet file")
  io.println("  -r Module::func <file.jet>    Compile and run a module function")
  io.println("  build [dir]                   Compile all .jet files in directory")
  io.println("  escript <Module> [dir]         Build an escript executable")
  io.println("  release <Module> [dir]         Generate an OTP release")
  io.println("")
  io.println("Options:")
  io.println("  -o <path>      Output path (for build, escript, release)")
  io.println("  -h, --help     Show this help message")
  io.println("")
  io.println("Examples:")
  io.println("  jet Foo.jet                   Compile Foo.jet to Foo.beam")
  io.println("  jet -r Foo::run Foo.jet       Compile and run Foo::run()")
  io.println("  jet build src/                Compile all .jet files in src/")
  io.println("  jet escript MyApp src/         Bundle into ./myapp escript")
  io.println("  jet release MyApp src/         Generate release in _release/")
}

@external(erlang, "jet_cli_ffi", "write_beam")
fn write_beam(path: String, binary: BitArray) -> Result(Nil, String)

@external(erlang, "jet_cli_ffi", "call_module_func")
fn call_module_func(module: String, func: String) -> Nil

@external(erlang, "jet_cli_ffi", "add_code_path")
fn add_code_path(dir: String) -> Nil

@external(erlang, "jet_cli_ffi", "setup_code_paths")
fn setup_code_paths() -> Nil

@external(erlang, "jet_cli_ffi", "get_stdlib_beam_dir")
fn get_stdlib_beam_dir() -> String

@external(erlang, "jet_cli_ffi", "do_build_escript")
fn do_build_escript(
  app_module: String,
  beam_dirs: List(String),
  output: String,
) -> Result(Nil, String)

@external(erlang, "jet_cli_ffi", "do_build_release")
fn do_build_release(
  app_module: String,
  beam_dirs: List(String),
  output: String,
) -> Result(Nil, String)

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil
