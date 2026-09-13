#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]
use anyhow::Result;
use clap::{Parser, Subcommand};
use std::{
    io::{Read, Write},
    net::IpAddr,
    path::PathBuf,
};

#[derive(Parser)]
#[command(
    name = "Rime Q Sync",
    version,
    about = "Rime Q personal dictionary device group service"
)]
struct Args {
    #[command(subcommand)]
    command: Command,
}
#[derive(Subcommand)]
enum Command {
    Serve {
        #[arg(long)]
        root: PathBuf,
        #[arg(long, default_value = "0.0.0.0")]
        bind: IpAddr,
        #[arg(long, default_value_t = 0)]
        port: u16,
        #[arg(long)]
        isolated: bool,
        #[arg(long)]
        no_discovery: bool,
        /// Exit with the native input process; never leave a background orphan.
        #[arg(long)]
        parent_pid: Option<u32>,
    },
    /// Read one authenticated local command from standard input. Never use command-line secrets.
    Control {
        #[arg(long)]
        root: PathBuf,
    },
}
#[tokio::main]
async fn main() {
    if let Err(e) = run().await {
        let _ = writeln!(std::io::stderr(), "Rime Q Sync: {e}");
        std::process::exit(1);
    }
}
async fn run() -> Result<()> {
    match Args::parse().command {
        Command::Serve {
            root,
            bind,
            port,
            isolated,
            no_discovery,
            parent_pid,
        } => rimeq_sync::service::run(root, bind, port, isolated, no_discovery, parent_pid).await,
        Command::Control { root } => {
            let mut input = Vec::new();
            std::io::stdin()
                .take((rimeq_sync::service::MAX_CONTROL + 1) as u64)
                .read_to_end(&mut input)?;
            anyhow::ensure!(
                input.len() <= rimeq_sync::service::MAX_CONTROL,
                "control request exceeds limit"
            );
            let value = rimeq_sync::service::client(&root, serde_json::from_slice(&input)?).await?;
            serde_json::to_writer(std::io::stdout(), &value)?;
            Ok(())
        }
    }
}
