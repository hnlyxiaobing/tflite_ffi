# stub/ — 桌面确定性 C stub 运行时（实现轮）

`mb_tfl_stub.c` 提供 API.md 所列 **15 个 `mb_tfl_*` 公开 shim** 的确定性模拟实现，
使 `moon build` / `moon test` 在 Windows (MSVC) 上真实编译、链接、运行。

> **桌面确定性 stub**；真实 `libtensorflowlite_c` 对接与数值对齐
> （<1e-4 对 Python `tflite-runtime`）留待 R2。

## 模型格式 STF1（小端）

| 偏移 | 字段 | 说明 |
|---|---|---|
| 0 | `magic` | `'S','T','F','1'` |
| 4 | `version` u32 | = 1 |
| 8 | `input_count` u32 | 1..8 |
| 12 | `output_count` u32 | 1..8 |
| 16 | `scale` f32 | invoke 的确定性逐元素缩放因子 |
| 20 | 张量记录 × (in+out) | 见下；末尾不允许尾随字节 |

张量记录：`name_len` u32(1..63)、`name` 字节(UTF-8)、`dtype` u32
(0=F32 1=F16 2=I32 3=U8 4=I8 5=I64)、`rank` u32(1..8)、`dims` rank×i32
（输入必须 ≥1；输出允许 `-1` = allocate_tensors 时镜像 input 0 同轴尺寸）、
`qscale` f32、`qzero` i32。约束：每维 ≤ 2^20，单张量元素数 ≤ 2^20。

## 运行时语义

- **invoke**：输出 `j` 取源输入 `inputs[j % input_count]`；前
  `min(src_elems, dst_elems)` 个元素 `out[k] = scale * src[k]`
  （按各自 dtype 解释，整数截断并饱和），其余输出元素为 0。完全确定性。
- **options**：`threads` 必须在 `interpreter_create` 前设置为 ≥1，
  否则 `interpreter_create` 返回 NULL；创建后 options 即可释放。
- **tensor**：借用句柄，随 interp 释放失效，不单独释放。
- **resize_input**：更新输入形状并使全部缓冲失效（未分配）；
  之后必须 `allocate_tensors` 才能 copy/invoke（否则状态码 2）。
  `allocate_tensors` 同时重新解析输出动态尺寸。
- **状态码**：0 = ok；1 = 通用错误（NULL/越界/尺寸不符）；2 = NOT_ALLOCATED。

## 私有符号（非公开 shim）

`tflite_ffi_private_{model,options,interp}_alive`（句柄存活探测）与
`tflite_ffi_private_tensor_meta`（张量元数据查询）是 MoonBit 层与本 stub
之间的内部 ABI，**不属于** API.md 的 15 个公开 shim，不出现在
`pkg.generated.mbti`。R2 对接真实 `c_api.h` 时映射到
`TfLiteTensorName/Dims/Type/ByteSize/QuantizationParams` 等。
