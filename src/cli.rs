use std::path::PathBuf;

use clap::Parser;

#[derive(Debug, Parser)]
#[command(name = "mp", version, about = "Markdown previewer in terminal")]
struct Args {
    #[arg(name = "FILE", required = true, help = "Markdown file to preview")]
    file: PathBuf,
}

pub fn run() -> anyhow::Result<()> {
    let args = Args::parse();

    println!("Previewing file: {:?}", args.file);

    Ok(())
}
