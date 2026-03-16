import argv
import jet/cli

pub fn main() {
  cli.run(argv.load().arguments)
}
