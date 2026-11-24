// wasmscan scan FILE      for each defined function: its operator count, then the byte offset (from the start of
//                         its body) of every operator whose NaN result the deterministic profile canonicalizes:
//                         float arithmetic, min/max, sqrt, rounding, promote and demote (not neg/abs/copysign or
//                         the reinterprets, which move bits exactly)
// wasmscan validate FILE  "valid", or the validator's error
use std::env;
use wasmparser::{Operator, Parser, Payload, Validator, WasmFeatures};

fn main() {
    let a: Vec<String> = env::args().collect();
    let bytes = std::fs::read(&a[2]).expect("read");
    if a[1] == "validate" {
        let mut v = Validator::new_with_features(WasmFeatures::all());
        match v.validate_all(&bytes) {
            Ok(_) => println!("valid"),
            Err(e) => { println!("invalid: {e}"); std::process::exit(1) }
        }
        return;
    }
    let mut f = 0;
    for p in Parser::new(0).parse_all(&bytes) {
        if let Payload::CodeSectionEntry(body) = p.expect("parse") {
            let start = body.range().start;
            let mut reader = body.get_operators_reader().expect("ops");
            let mut n = 0;
            let mut hits = Vec::new();
            while !reader.eof() {
                let (op, off) = reader.read_with_offset().expect("op");
                n += 1;
                use Operator::*;
                let hit = matches!(op, F32Ceil | F32Floor | F32Trunc | F32Nearest | F32Sqrt | F32Add | F32Sub | F32Mul
                    | F32Div | F32Min | F32Max | F64Ceil | F64Floor | F64Trunc | F64Nearest | F64Sqrt | F64Add | F64Sub
                    | F64Mul | F64Div | F64Min | F64Max | F32DemoteF64 | F64PromoteF32);
                if hit { hits.push(format!("{}", off - start)); }
            }
            println!("{f} {n} {}", hits.join(","));
            f += 1;
        }
    }
}
