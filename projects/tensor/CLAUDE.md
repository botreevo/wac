# Notes for whoever works on this next

README.md says what this is and where it stands; read it first.

- **Two oracles, and no expectations typed from memory where one applies.** A backward rule is checked against
  finite differences (`Check.gradient` in `test/check.wac`); a GPU kernel against the CPU backend
  (`example/gpucheck.wac`). Adding an operation means adding it to both. Where a test does compare with typed numbers,
  work them out with NumPy or by hand first — three of the first expected values here were wrong, not the code.
- **A new operation should almost never need a new kernel.** Write it in `tensor.wac` from existing operations and it
  gets its gradient and its GPU version free. A kernel is for something no composition can do efficiently.
- **The GPU check needs Chromium with WebGPU**: `NODE_PATH=$(npm root -g) node tools/gpucheck.js dist/gpucheck`
  after `wac task gpucheck:build`. Headless Chromium gets WebGPU from `--enable-unsafe-webgpu --use-angle=swiftshader`
  on a page served from localhost (not `about:blank`, which is not a secure context). `wac task shaders` compiles every
  WGSL program, in both element types, the same way (`tools/shadercheck.js`).
- **A kernel is written twice, in WGSL (`src/gpu/wgsl.wac`) and MSL (`src/metal/msl.wac`)**, and `GpuBackend` runs
  either. The Metal check needs a Mac: `wac task metal:server`, start `dist/wac-tensor-metal`, then `wac task
  metal:check`. `WAC_METAL_PROFILE=1` on the server prints the GPU's time for each program when a run ends.
- **Every kernel has an `F16` path, and the GPU check runs every case in both types.** A new kernel reads its inputs
  through `L_<name>` and, if elementwise, is a `value(i)` that `elementwise` wraps (`src/gpu/wgsl.wac`); one that
  writes anything else writes `F32` and the backend `settle`s it. On the CPU, `made` does the rounding.
- **The pin on wac-web is a master commit with `wac.gpu` in the browser host.** The pin names GitHub, as wac's do;
  until the owner syncs that commit there, `wac update` cannot fetch it: put it in the cache by hand — `git archive <commit> | tar -x -C
  ~/.wac/cache/git/https%3A%2F%2Fgithub.com%2Fvoltrevo%2Fwac-web.git/<commit>` and `touch pack.pack` there, which is
  what wac's `tools/fill-cache.sh` does.
- **wac is pinned by the `wac` you build**: this was written against wac `701028301`. When wac gets in the way, write it
  down in `docs/wac-asks.md` with a reproduction and work around it here.
- Comments explain *why*, in full sentences, as wac's own do. There are no users and no legacy: when nothing needs a
  thing, delete it.
