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

The capabilities: n-dimensional `f32` tensors with NumPy broadcasting; elementwise maths and activations; reductions
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

**Every tensor is `f32`.** It is what WebGPU computes in everywhere and what TensorFlow trains in by default. Index
tensors (`take`, `argMax`, `oneHot`) hold their integers as `f32`, exact to 2²⁴. There are no other dtypes.

## The backends

Everything above is written once (`src/tensor.wac`) against fifteen kernels (`src/backend.wac`): elementwise unary
and binary (broadcast by strides), select, row reduction and arg-reduction, batched matrix product, strided gather,
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

The host side is on wac-web's `gpu` branch (`tools/build.wac`, `wac.gpu` in `programSide`), and this repository's
`wac.json5` pins that commit.

## Checking it

```sh
wac task test             # 26 tests, about a second: every op, every gradient, every optimizer's first step
wac task gpucheck:build   # the GPU check as a page
wac task gpucheck         # ...run in headless Chromium: PASS 64
```

- **Gradients against finite differences.** Every backward rule — 21 unary, 10 binary with broadcasting, 9 reductions,
  10 shape operations, 6 matrix products, 6 convolutions and pools — is checked against central differences
  (`test/grad_test.wac`). It needs no second implementation to agree with.
- **The GPU against the CPU.** `example/gpucheck.wac` runs 63 cases — every kernel and every unary and binary
  operation, large and awkward shapes (more rows than a dispatch grid is wide, matrices that do not divide into
  tiles), gradients through convolution, gather and pooling — and 200 steps of training, on both backends from the
  same numbers. A mutation in one shader turns it red. Run on SwiftShader, Chromium's software Vulkan, it needs no GPU.
- **Optimizers exactly.** Each optimizer's first one or two steps are compared with the numbers worked by hand.
- **Models learn.** An MLP learns XOR; a small CNN tells bright rows from bright columns.

## Not here yet

- Recurrent layers and attention, as layers. Both are expressible today — `matmul`, `softmax` and `concat` are all
  there and differentiable — but there is no `Lstm` or `MultiHeadAttention`.
- Saving and loading weights. `Variable`s are plain tensors; a format is the missing piece.
- Speed on the CPU. It is a reference. On the GPU the matrix product is tiled and the rest is one pass per kernel,
  with no fusion of elementwise chains.
- GPU scatter-add is a gather over every index per output element — WGSL has no float atomics — so an embedding's
  gradient costs rows × width × indices.
- Shape errors trap rather than explain: wac has no exceptions, and a `Result` from every operation would make
  `a.matmul(b).add(c)` unwritable.

`docs/wac-asks.md` records where wac got in the way, with reproductions.
