# wac-tensor

Tensors, gradients, layers and optimizers in wac — TensorFlow's capabilities with an API started again from
scratch — on a CPU backend that runs anywhere wac does, and a WebGPU backend that runs in a browser.

```wac
import { Device, Tensor } from "tensor";
import { Activation, Dense, Layer, Sequential, sparseSoftmaxCrossEntropy } from "tensor";
import { Adam } from "tensor";

Device d = Device.cpu();                       // or: await gpuDevice(page.sys.host, warn)
Sequential model = Sequential.of([
  Dense.create(d, 784, 128, Activation.Relu),
  Dense.create(d, 128, 10, Activation.Linear),
]);
Adam opt = Adam.create(0.001);

Tensor loss = opt.minimize(() => sparseSoftmaxCrossEntropy(model.apply(x, true), labels), model.params());
```

`wac run example/spiral.wac` trains a three-layer network on two interleaved spirals in two seconds, on the CPU.

## What is the same as TensorFlow

The capabilities: n-dimensional `f32` and `f16` tensors with NumPy broadcasting; elementwise maths and activations; reductions
over any axes; matrix products with batching and either side transposed; reshape, transpose, slice, pad, concat,
split, tile, gather and one-hot; 2-D convolution (strides, `Same`/`Valid` padding, dilation), its transpose, and max
and average pooling, in NHWC with `[kh, kw, in, out]` filters; reverse-mode gradients of anything built from those,
including gradients of gradients; dense, convolutional, embedding, dropout, layer- and batch-norm layers; the usual
losses; SGD, momentum (and Nesterov), RMSProp, Adagrad, Adam and AdamW; global-norm clipping; Glorot and He
initialisers; seeded random tensors; and explicit memory scopes (`tidy`) for a GPU's buffers.

The numbers are TensorFlow's where it has an opinion: `Same` padding puts the odd pixel bottom-right, average pooling
counts only the part of a window inside the image, `round` takes a tie to the even neighbour, `pow` of a negative base
answers when the exponent is whole, an index outside a gather reads zeros, and `max` sends a gradient to every element
that ties.

## What is different

**The device is a value.** TensorFlow keeps a global engine — the backend, the tape, the `tidy` stack, the random
state. wac has no mutable globals, so all of that is a `Device`, and every tensor carries the one it was made on. Two
devices side by side is ordinary (`example/gpucheck.wac` runs every operation on both); mixing their tensors in one
operation is refused rather than silently copied — `await t.to(other)` says it.

**Every operation is a method, and arithmetic is operators.** `x.matmul(w).add(b).relu()`, or `x.matmul(w) + b`.
A scalar fits wherever a tensor does: `t * 2.0`, `1.0 - t`. There are no default arguments, because wac has none:
`t.sum([], false)` is "every axis, not kept", said in full, and `t.sum([1], true)` is the other common case.

**Gradients are a function of a function.** There is no tape object to manage:

```wac
Gradients g = d.gradients(() => loss(w, b), [w, b]);   // g.value, g.grads[0], g.grads[1]
```

Each backward rule is written in tensor operations, so it runs on whichever backend the forward pass did, and it is
recorded when an outer `gradients` is recording — a second derivative is two nested calls. `t.detach()` stops a
gradient.

**A layer is told its input size when it is made**, so it has its weights the moment it exists and a shape mistake
surfaces where the layer was written, not at its first call. `apply(x, training)` takes the mode as an argument, so
dropout and batch normalisation are never left in the wrong one.

**A `Variable` is a `Tensor`.** Anywhere a tensor goes, a variable goes; `v.assign(t)` replaces its numbers, and no
`tidy` disposes it. Optimizers keep their per-variable state by the variable's identity, so one optimizer trains any
set of variables.

**Memory is explicit and cheap to get right.** `d.tidy(() => …)` disposes every tensor made inside but the one
returned; `optimizer.minimize` is already a tidy step that keeps only the loss. On the CPU this is bookkeeping; on a
GPU it is the difference between a training loop and a leak. A use after dispose traps on both.

**Two element types: `F32` and `F16`, both computed in `f32`.** A half tensor is stored as halves — half the memory
and bandwidth — and every operation reads it as `f32`, computes, and rounds its result once, which is what
mixed-precision training does: a sum of 4096 halves is 4096, where accumulating in halves would stop at 2048. Types
never mix silently: `a.add(b)` with one of each traps, and `t.cast(DType.F16)` says it, its gradient cast back — so
f32 weights under an f16 computation train. A number takes its tensor's type (`half * 2.0` stays half). `d.dtype =
DType.F16` before a model is made makes every new tensor, and so every weight, a half. Index tensors (`take`,
`argMax`, `oneHot`) hold their integers as floats — `argMax` always answers `F32`, exact to 2²⁴.

*Why only these two:* WGSL computes in `f32`, `i32` and `u32`, with `f16` as an optional extension (`shader-f16`) not
every adapter has; there is no `f64`, no `bfloat16`, and no 8- or 64-bit integer arithmetic. So halves here are packed
two to a `u32` and unpacked with core WGSL's `unpack2x16float` — no extension, every adapter, the arithmetic in `f32`
either way. An `I32` type for integer arithmetic is the natural next one; it is not here yet.

## A tiny GPT

`example/gpt/` is a character-level transformer language model — GPT-2's architecture at toy size: token and
position embeddings, pre-norm blocks of causal multi-head attention and a GELU feed-forward network, a final layer norm,
a linear head — and what training and sampling one takes. `MultiHeadAttention` and `TransformerBlock` are library
layers, their gradients checked against finite differences like everything else, and a test holds that no position's
output changes when only later positions do.

```sh
wac task gpt:train      # names, on the CPU: 2000 steps in about ten minutes
wac task gpt:build      # the page that trains on WebGPU, with its texts beside it — serve dist/gpt
wac task gpt:check      # in headless Chromium: 20 steps on the GPU and the CPU agree at every step
```

On the 32,033 names of makemore's list, shuffled and with the last tenth held out, a model of 104,603 numbers (context
16, width 64, two layers of four heads) reaches a validation loss of **2.13** in 2000 steps of batch 32 on the CPU —
where a uniform guess scores 3.30 and a model of which letter follows which about 2.45 — and invents names like
*kaliah, micariah, nixanna, ezley, araela, jayelenn, samira*.

The page trains the same model, or a larger one on tiny Shakespeare (context 64, width 128, four layers), on the GPU,
and shows the loss, the speed and fresh samples as it goes; without WebGPU it trains on the CPU and says so. Its check
trains the names model twenty Adam steps on WebGPU and on the CPU from one seed: the losses agree to about seven
significant figures (2.781002 and 2.7810018 after the twentieth), so the whole model, forwards and backwards, computes
the same on both.

**Speed, honestly.** The CPU backend does about 0.28 s a step at this size; the profile is matrix products at roughly
1.2 GFLOP/s, which is scalar wasm over GC arrays. WebGPU speed could not be measured here: the only GPU in this
environment is SwiftShader, a software rasteriser, which managed ten steps a minute. A real GPU is the point of the
page, and is where a number for it should come from.

## The backends

Everything above is written once (`src/tensor.wac`) against sixteen kernels (`src/backend.wac`): elementwise unary
and binary (broadcast by strides), cast, select, row reduction and arg-reduction, batched matrix product, strided gather,
pad, im2col and col2im, take and scatter-add, fill. A transpose, slice and broadcast are one `gather`; a convolution is
`im2col` and a matrix product; pooling is `im2col` and a reduction. Adding an operation almost never needs a kernel.

**CPU** (`src/cpu.wac`) is the reference: loops over `f32[]`, the most direct reading of each kernel's definition,
reductions summed in `f64`.

**WebGPU** (`src/gpu/`) is a WGSL program per kind of kernel, sizes passed in a uniform so each compiles once. It
reaches the GPU through **`wac.gpu`**, a capability — wac programs import nothing from JavaScript — that wac-web's
browser host answers with `navigator.gpu`. The protocol (`src/gpu/line.wac`) is WebGPU's compute half in five verbs:
make a buffer, write it, run a program over buffers, read one back, free one; everything but a read is batched, so a
training step is one message. Reading is the only thing that waits, which is why `t.values()` answers a `Ticket` and
`t.item()` is CPU-only.

```wac
export async i32 main(Page page) {
  Result<Device, string> gpu = await gpuDevice(page.sys.host, (string s) => { page.log(s); });
  Device d = gpu.ok()!;
  …
  f32[] numbers = await loss.values();
}
```

The host side is in wac-web (`tools/build.wac`, `wac.gpu` in `programSide`), and this repository's `wac.json5` pins a
master commit that has it.

## Checking it

```sh
wac task test             # 35 tests, about a second: every op, every gradient, every optimizer's first step, halves
wac task gpucheck:build   # the GPU check as a page
wac task gpucheck         # ...run in headless Chromium: PASS 128
wac task shaders          # every WGSL program, in both types, compiled in Chromium: 100 of them
```

- **Gradients against finite differences.** Every backward rule — 21 unary, 10 binary with broadcasting, 9 reductions,
  10 shape operations, 6 matrix products, 6 convolutions and pools — is checked against central differences
  (`test/grad_test.wac`). It needs no second implementation to agree with.
- **The GPU against the CPU.** `example/gpucheck.wac` runs 63 cases — every kernel and every unary and binary
  operation, large and awkward shapes (more rows than a dispatch grid is wide, matrices that do not divide into
  tiles), gradients through convolution, gather and pooling — in `F32` and again in `F16`, on both backends from the
  same numbers; then 200 steps of training compared step for step, and a model in halves trained on the GPU. A
  mutation in one shader turns it red, as does swapping the two halves of a packed word. Run on SwiftShader,
  Chromium's software Vulkan, it needs no GPU.
- **Halves bit for bit.** The conversions agree with IEEE 754 (and NumPy) at the edges — ties to even, the largest
  finite half, overflow to infinity, the subnormals — and every one of the 65536 halves survives the round trip.
- **Optimizers exactly.** Each optimizer's first one or two steps are compared with the numbers worked by hand.
- **Models learn.** An MLP learns XOR; a small CNN tells bright rows from bright columns.

## Not here yet

- Recurrent layers. An LSTM is expressible today — `matmul`, `sigmoid`, `tanh` and `concat` are all there and
  differentiable — but there is no `Lstm` layer.
- Saving and loading weights. `Variable`s are plain tensors; a format is the missing piece — a trained GPT is gone
  when its page closes.
- Speed on the CPU. It is a reference. On the GPU the matrix product is tiled and the rest is one pass per kernel,
  with no fusion of elementwise chains.
- GPU scatter-add is a gather over every index per output element — WGSL has no float atomics — so an embedding's
  gradient costs rows × width × indices.
- Shape errors trap rather than explain: wac has no exceptions, and a `Result` from every operation would make
  `a.matmul(b).add(c)` unwritable.

`docs/wac-asks.md` records where wac got in the way, with reproductions.
