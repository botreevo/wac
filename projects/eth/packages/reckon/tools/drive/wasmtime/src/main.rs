//! `drive-wasmtime IN OUT`: wacc, as the bootstrap ladder built it, compiling a program, on wasmtime
//! (docs/drive-machine.md). The tail of wac's `ladder --with-wacc`, taken apart from the ladder:
//!
//! IN holds `wacc` (the module wac-L5 built from wacc with `bootstrap/drivers/spec_cases.wac` appended), `tree/` (the
//! sources), `entry` (the program's path within tree/), `name` (the module name the manifest records) and `grants`
//! (`--allow-…` names, separated by spaces). The file set is wac's own (`flatten::file_set`, `key_of`); wacc is driven
//! through its driver a byte at a time, as `bootstrap/rust-ladder/src/wacc.rs` drives it: `emitFiles`, then `seal`.
//! The sealed module goes to OUT. Exit 0 with OUT written; exit 1 when wacc declines the program; anything else is 2.

#[allow(dead_code)]
mod flatten {
    include!(concat!(env!("OUT_DIR"), "/flatten.rs"));
}

use std::process::ExitCode;
use wasmtime::{Config, Engine, Instance, Module, Store};

struct Wacc {
    store: Store<()>,
    inst: Instance,
}

impl Wacc {
    fn call(&mut self, name: &str, args: &[i32]) -> Result<i32, String> {
        let f = self.inst.get_func(&mut self.store, name).ok_or(format!("wacc exports no {name}"))?;
        let vals: Vec<wasmtime::Val> = args.iter().map(|a| wasmtime::Val::I32(*a)).collect();
        let mut out = vec![wasmtime::Val::I32(0); f.ty(&self.store).results().len()];
        f.call(&mut self.store, &vals, &mut out).map_err(|e| format!("wacc trapped in {name}: {e}"))?;
        Ok(match out.first() { Some(wasmtime::Val::I32(n)) => *n, _ => 0 })
    }
    fn feed(&mut self, alloc: &str, put: &str, text: &[u8]) -> Result<(), String> {
        self.call(alloc, &[text.len() as i32])?;
        for (i, b) in text.iter().enumerate() { self.call(put, &[i as i32, *b as i32])?; }
        Ok(())
    }
    fn take(&mut self, n: i32, at: &str) -> Result<Vec<u8>, String> {
        (0..n).map(|i| self.call(at, &[i]).map(|b| b as u8)).collect()
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 { eprintln!("usage: drive-wasmtime IN OUT"); return ExitCode::from(2); }
    match run(&args[1], &args[2]) {
        Ok(()) => ExitCode::SUCCESS,
        Err((code, why)) => { eprintln!("drive-wasmtime: {why}"); ExitCode::from(code) }
    }
}

fn read(dir: &str, name: &str) -> Result<String, (u8, String)> {
    std::fs::read_to_string(format!("{dir}/{name}")).map(|s| s.trim().to_string()).map_err(|e| (2, format!("{name}: {e}")))
}

fn run(dir: &str, out: &str) -> Result<(), (u8, String)> {
    let dir = std::fs::canonicalize(dir).map_err(|e| (2, e.to_string()))?.to_string_lossy().into_owned();
    let out = std::path::absolute(out).map_err(|e| (2, e.to_string()))?;
    let wasm = std::fs::read(format!("{dir}/wacc")).map_err(|e| (2, format!("wacc: {e}")))?;
    let entry = read(&dir, "entry")?;
    let name = read(&dir, "name")?;
    let grants = grants_of(&read(&dir, "grants")?);
    // The file set from inside the tree, as the ladder computes it from inside wac's checkout.
    std::env::set_current_dir(format!("{dir}/tree")).map_err(|e| (2, e.to_string()))?;
    let (paths, sources) = flatten::file_set(std::path::Path::new(&entry)).map_err(|e| (2, e))?;
    let key = flatten::key_of(std::path::Path::new(&entry)).map_err(|e| (2, e))?;
    let mut config = Config::new();
    config.wasm_function_references(true);
    config.wasm_gc(true);
    config.collector(wasmtime::Collector::Copying);
    let engine = Engine::new(&config).map_err(|e| (2, e.to_string()))?;
    let module = Module::new(&engine, &wasm).map_err(|e| (2, format!("wacc is not a module wasmtime accepts: {e}")))?;
    let mut store = Store::new(&engine, ());
    let inst = Instance::new(&mut store, &module, &[]).map_err(|e| (2, e.to_string()))?;
    let mut w = Wacc { store, inst };
    let e2 = |e: String| (2u8, e);
    w.call("drv_files", &[paths.len() as i32]).map_err(e2)?;
    for (p, src) in paths.iter().zip(&sources) {
        w.feed("drv_alloc", "drv_setByte", src.as_bytes()).map_err(e2)?;
        w.feed("drv_allocName", "drv_setNameByte", p.as_bytes()).map_err(e2)?;
        w.call("drv_pushFile", &[]).map_err(e2)?;
    }
    w.feed("drv_allocName", "drv_setNameByte", key.as_bytes()).map_err(e2)?;
    let n = w.call("drv_buildFiles", &[]).map_err(e2)?;
    if n <= 8 {
        let m = w.call("drv_declineFiles", &[]).map_err(e2)?;
        let why = w.take(m, "drv_declineByte").map_err(e2)?;
        return Err((1, format!("wacc declined {entry}: {}", String::from_utf8_lossy(&why))));
    }
    w.feed("drv_allocEntryName", "drv_setEntryNameByte", entry.as_bytes()).map_err(e2)?;
    w.feed("drv_allocWasmName", "drv_setWasmNameByte", name.as_bytes()).map_err(e2)?;
    let n = w.call("drv_seal", &[grants]).map_err(e2)?;
    let sealed = w.take(n, "drv_byteAt").map_err(e2)?;
    std::fs::write(&out, sealed).map_err(|e| (2, e.to_string()))?;
    Ok(())
}

/// `manifestOf`'s bitfield: read 1, write 2, net 4, env 8, run 16 (bootstrap/js/wacc.js's GRANTS).
fn grants_of(names: &str) -> i32 {
    let mut bits = 0;
    for n in names.split_whitespace() {
        bits |= match n { "read" => 1, "write" => 2, "net" => 4, "env" => 8, "run" => 16, _ => 0 };
    }
    bits
}
