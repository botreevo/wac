//! `seam-wasmtime IN OUT`: one rung of wac's bootstrap ladder, on wasmtime (docs/seam-machine.md).
//!
//! IN is a directory holding `module` (the rung, a wasm module), `source` (text) and, for the interpreter's shape, an
//! optional `subject`. The rung is one of two shapes, told apart by what it exports:
//! - the L1 interpreter (`seam_at`, `run_at`): the text, NUL-terminated, at `seam_at()`; `run_at(at)` answers where
//!   its answer starts, NUL-terminated. With a `subject`, the text is `source`, then `\n(compile (quote (`, the
//!   subject, and `)))\n`: an L1 program compiling an L2 one, as bootstrap/js/ladder.js's `l2ToL0` makes it.
//! - a compiler rung (`seam_src`, `seam_out`, `compile`): the text, NUL-terminated, at `seam_src()`;
//!   `compile(src, out)` answers the length of what it wrote at `seam_out()`.
//! The answer's bytes go to OUT. Exit 0 with OUT written; anything else (no such shape, a trap) exits 2: no answer.

use std::process::ExitCode;
use wasmtime::{Config, Engine, Instance, Memory, Module, Store, TypedFunc};

fn fail(why: String) -> ExitCode {
    eprintln!("seam-wasmtime: {why}");
    ExitCode::from(2)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: seam-wasmtime IN OUT");
        return ExitCode::from(2);
    }
    match run(&args[1]) {
        Ok(answer) => match std::fs::write(&args[2], answer) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => fail(format!("cannot write {}: {e}", args[2])),
        },
        Err(e) => fail(e),
    }
}

fn run(dir: &str) -> Result<Vec<u8>, String> {
    let wasm = std::fs::read(format!("{dir}/module")).map_err(|e| format!("module: {e}"))?;
    let source = std::fs::read(format!("{dir}/source")).map_err(|e| format!("source: {e}"))?;
    let subject = std::fs::read(format!("{dir}/subject")).ok();
    let mut config = Config::new();
    config.wasm_function_references(true);
    config.wasm_gc(true);
    config.collector(wasmtime::Collector::Copying);
    let engine = Engine::new(&config).map_err(|e| e.to_string())?;
    let module = Module::new(&engine, &wasm).map_err(|e| format!("not a module wasmtime accepts: {e}"))?;
    let mut store = Store::new(&engine, ());
    let inst = Instance::new(&mut store, &module, &[]).map_err(|e| format!("cannot instantiate: {e}"))?;
    let memory = inst.get_memory(&mut store, "memory").ok_or("no exported memory")?;
    if let Ok(seam_at) = inst.get_typed_func::<(), i32>(&mut store, "seam_at") {
        let mut text = source;
        if let Some(s) = subject {
            text.extend_from_slice(b"\n(compile (quote (");
            text.extend_from_slice(&s);
            text.extend_from_slice(b")))\n");
        }
        let at = seam_at.call(&mut store, ()).map_err(|e| format!("trap: {e}"))? as usize;
        put(&mut store, &memory, at, &text)?;
        let run_at: TypedFunc<i32, i32> = inst.get_typed_func(&mut store, "run_at").map_err(|e| e.to_string())?;
        let answer = run_at.call(&mut store, at as i32).map_err(|e| format!("trap: {e}"))? as usize;
        let data = memory.data(&store);
        let mut end = answer;
        while end < data.len() && data[end] != 0 { end += 1; }
        return Ok(data[answer.min(data.len())..end].to_vec());
    }
    let src: TypedFunc<(), i32> = inst.get_typed_func(&mut store, "seam_src").map_err(|_| "neither seam shape: no seam_at, no seam_src")?;
    let out: TypedFunc<(), i32> = inst.get_typed_func(&mut store, "seam_out").map_err(|e| e.to_string())?;
    let compile: TypedFunc<(i32, i32), i32> = inst.get_typed_func(&mut store, "compile").map_err(|e| e.to_string())?;
    if subject.is_some() { return Err("a subject is only for the interpreter's shape".into()); }
    let s = src.call(&mut store, ()).map_err(|e| format!("trap: {e}"))? as usize;
    let o = out.call(&mut store, ()).map_err(|e| format!("trap: {e}"))? as usize;
    put(&mut store, &memory, s, &source)?;
    let len = compile.call(&mut store, (s as i32, o as i32)).map_err(|e| format!("trap: {e}"))? as usize;
    let data = memory.data(&store);
    if o + len > data.len() { return Err("the answer runs past memory".into()); }
    Ok(data[o..o + len].to_vec())
}

/// The text and a NUL at `at`, growing memory if it does not fit (the hosts write into what the rung already has).
fn put(store: &mut Store<()>, memory: &Memory, at: usize, text: &[u8]) -> Result<(), String> {
    let need = at + text.len() + 1;
    let have = memory.data_size(&*store);
    if need > have {
        let pages = ((need - have) + 65535) / 65536;
        memory.grow(&mut *store, pages as u64).map_err(|e| format!("cannot grow memory: {e}"))?;
    }
    let data = memory.data_mut(&mut *store);
    data[at..at + text.len()].copy_from_slice(text);
    data[at + text.len()] = 0;
    Ok(())
}
