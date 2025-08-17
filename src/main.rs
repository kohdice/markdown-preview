mod cli;
mod finder;

use cli::run;

fn main() -> anyhow::Result<()> {
    run()
}
