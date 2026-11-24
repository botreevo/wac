// How `host/faults.ts` classifies a host's error — a unit test of TypeScript, with no wac in it.
//
// The numbering it shares with `std/platform.wac`, and the phrases on each side, are compared by
// `test/wac/faultsagree_test.wac`, which reads both files as source. What stays here is what only the
// TypeScript can be asked: given this exception, which category.

import {
  FAULT_DENIED,
  FAULT_NONE,
  FAULT_NOT_A_DIR,
  FAULT_NOT_GRANTED,
  FAULT_OTHER,
  faultOf,
  statFault,
} from "../host/faults.ts";

/** Local, because this repo has no third-party dependencies. */
function assertEquals<T>(got: T, want: T, msg?: string): void {
  if (got !== want) {
    throw new Error(
      `assertEquals failed${msg === undefined ? "" : ` — ${msg}`}\n` +
        `  got:  ${JSON.stringify(got)}\n  want: ${JSON.stringify(want)}`,
    );
  }
}

Deno.test("a grant that was never given is not classified as denial", () => {
  // The last line of `faultOf` matches on text, and it read `not granted` as `FAULT_DENIED` for as long as
  // `FAULT_NOT_GRANTED` had existed beside it — so the distinction the category was added for was
  // unobservable from anything that arrived as a message.
  assertEquals(faultOf(new Error("filesystem read not granted to this application")), FAULT_NOT_GRANTED);
  assertEquals(faultOf(new Error("network access is not granted")), FAULT_NOT_GRANTED);
  // And a real refusal by the operating system stays denial.
  assertEquals(faultOf(Object.assign(new Error("EACCES"), { code: "EACCES" })), FAULT_DENIED);
  assertEquals(faultOf(new Error("something else entirely")), FAULT_OTHER);
});

Deno.test("`statFault` still calls absence an answer", () => {
  // Everything except the unknowable cases is `FAULT_NONE`, because a `stat` that found nothing was answered.
  assertEquals(statFault(Object.assign(new Error("ENOENT"), { code: "ENOENT" }), "/x"), FAULT_NONE);
  assertEquals(statFault(Object.assign(new Error("EACCES"), { code: "EACCES" }), "/x"), FAULT_DENIED);
  // And a category no `stat` should carry stays out: `EEXIST` cannot come from a `stat` at all, and if
  // some host ever produced one the answer is still "nothing here" rather than a failure.
  assertEquals(statFault(Object.assign(new Error("EEXIST"), { code: "EEXIST" }), "/x"), FAULT_NONE);
});

Deno.test("`ENOTDIR` reaches a `Stat` as a category, without making it unanswerable", () => {
  // The one fault that rides along with sound facts. This asserted `FAULT_NONE` until 2026-08-08, on the
  // argument that a fault here would break `test -e f/g` — true of the old `Stat.answered`, which called
  // any fault unanswerable. It cost the three tools that report an absence to a person: `ls f/g`, `cd
  // f/g` and `stat f/g` all said "No such file or directory" where GNU says "Not a directory". The half
  // that keeps `test` honest is `Stat.answered`, asserted by `packages/box/test/wac/notdir_test.wac`; the
  // words are `faultsagree_test.wac`'s.
  assertEquals(statFault(Object.assign(new Error("ENOTDIR"), { code: "ENOTDIR" }), "/x/y"), FAULT_NOT_A_DIR);
});
