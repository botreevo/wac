// wac's own flatten.rs, from the source the machine names (WAC_SRC: a wac checkout at the pinned commit), so this runner
// computes the file set with wac's Rust implementation and not a copy of it. Its `//!` lines are inner doc comments,
// which `include!` cannot take, and so are dropped; nothing else changes.
fn main() {
    let src = std::env::var("WAC_SRC").expect("set WAC_SRC to a wac checkout at the pinned commit");
    let path = format!("{src}/bootstrap/rust-ladder/src/flatten.rs");
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"));
    let kept: Vec<&str> = text.lines().filter(|l| !l.trim_start().starts_with("//!")).collect();
    let out = std::env::var("OUT_DIR").unwrap();
    std::fs::write(format!("{out}/flatten.rs"), kept.join("\n")).unwrap();
    println!("cargo:rerun-if-changed={path}");
    println!("cargo:rerun-if-env-changed=WAC_SRC");
}
