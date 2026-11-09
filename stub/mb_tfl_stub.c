/*
 * mb_tfl_stub.c — tflite_ffi 桌面确定性 C stub 运行时（CI 默认后端）
 *
 * 【定位】docs/API.md 所列 17 个 mb_tfl_* shim 符号（MoonBit 侧已收敛为包私有，冻结前 P0）的确定性模拟实现，
 * 使 moon build / moon test 在 Windows (MSVC) 上真实编译、链接、运行。
 * 桌面确定性 stub；真实 libtensorflowlite_c 对接与数值对齐
 * （<1e-4 对 Python tflite-runtime）留待 R2。
 *
 * 【模型格式 STF1】（全部小端）
 *   0  : magic 'S','T','F','1'
 *   4  : version  u32 = 1
 *   8  : input_count  u32 (1..8)
 *   12 : output_count u32 (1..8)
 *   16 : scale f32（invoke 的确定性逐元素缩放因子）
 *   20 : (input_count + output_count) × 张量记录（先输入后输出）：
 *          name_len u32 (1..63)
 *          name     name_len 字节 (UTF-8)
 *          dtype    u32 (0=Float32 1=Float16 2=Int32 3=UInt8 4=Int8 5=Int64)
 *          rank     u32 (1..8)
 *          dims     rank × i32：输入必须 >=1；输出允许 -1，
 *                   表示 allocate_tensors 时镜像 input 0 的同轴尺寸
 *          qscale   f32
 *          qzero    i32
 *   末尾位置必须恰好等于 size（不允许尾随字节）。
 *   约束：每维 <= 2^20，单张量元素数 <= 2^20。
 *
 * 【invoke 语义】对第 j 个输出张量：源 = inputs[j % input_count]；
 *   前 min(src_elems, dst_elems) 个元素做 out[k] = scale * src[k]
 *   （各自按 dtype 解释，浮点按 IEEE754、整数截断并饱和），其余输出元素为 0。
 *   顺序固定、无随机性，完全确定性。量化参数只体现在描述中，不做反量化。
 *
 * 【生命周期语义】
 *   - model：保存解析出的张量描述；interpreter_create 只引用 model，
 *     不转移所有权（model_delete 由调用方负责）。
 *   - options：threads 必须在 interpreter_create 之前设置为 >=1，
 *     否则 interpreter_create 返回 NULL；创建 interpreter 后 options 即可释放。
 *   - tensor：借用句柄（指向 interp 内部），随 interp 释放失效，不可单独释放。
 *   - resize_input：更新输入形状并使全部张量缓冲失效（未分配），
 *     必须 allocate_tensors 后才能 copy_from / copy_to / invoke
 *     （否则返回 2 = NOT_ALLOCATED）；allocate_tensors 同时重新解析
 *     输出张量的动态尺寸。
 *
 * 【状态码】0 = ok；1 = 通用错误（NULL / 越界 / 尺寸不符 / 非法参数）；
 *          2 = NOT_ALLOCATED（resize 后未 allocate_tensors）。
 *
 * 【私有符号】tflite_ffi_private_* 是本 MoonBit 层与 stub 之间的内部约定
 *  （句柄存活探测、张量元数据查询），不属于 docs/API.md 的 17 个 mb_tfl_* shim，
 *  不出现在 pkg.generated.mbti；R2 对接真实 c_api.h 时映射到
 *  TfLiteTensorName / Dims / Type / ByteSize / QuantizationParams 等。
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define MB_TFL_STUB_CAPI_VERSION 0x00010001

#define STUB_OK 0
#define STUB_ERR 1
#define STUB_NOT_ALLOCATED 2

#define STUB_MAX_RANK 8
#define STUB_MAX_TENSORS 8
#define STUB_MAX_ELEMS (1 << 20)
#define STUB_MAX_NAME 63

typedef struct {
  const uint8_t *p;
  int32_t n;
  int32_t pos;
} stub_reader;

typedef struct {
  char name[STUB_MAX_NAME + 1];
  int32_t name_len;
  int32_t dtype;
  int32_t rank;
  int32_t template_dims[STUB_MAX_RANK]; /* -1 = 动态（仅输出） */
  int32_t dims[STUB_MAX_RANK]; /* 解析后的当前尺寸 */
  int32_t byte_size;
  float qscale;
  int32_t qzero;
} stub_tmeta;

typedef struct {
  stub_tmeta tm;
  uint8_t *buf; /* NULL = 未分配 */
} stub_tensor;

typedef struct {
  int32_t input_count;
  int32_t output_count;
  float scale;
  stub_tmeta *inputs;
  stub_tmeta *outputs;
} stub_model;

typedef struct {
  int32_t threads_set;
  int32_t threads;
} stub_options;

typedef struct {
  const stub_model *model;
  int32_t allocated;
  stub_tensor *inputs;
  stub_tensor *outputs;
} stub_interp;

/* ---------------- 读取器（带边界检查） ---------------- */

static int stub_rd_u32(stub_reader *r, uint32_t *out) {
  const uint8_t *b;
  if (r->pos < 0 || r->pos + 4 > r->n) return 0;
  b = r->p + r->pos;
  *out = (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) |
         ((uint32_t)b[3] << 24);
  r->pos += 4;
  return 1;
}

static int stub_rd_i32(stub_reader *r, int32_t *out) {
  uint32_t u;
  if (!stub_rd_u32(r, &u)) return 0;
  *out = (int32_t)u;
  return 1;
}

static int stub_rd_f32(stub_reader *r, float *out) {
  uint32_t u;
  if (!stub_rd_u32(r, &u)) return 0;
  memcpy(out, &u, sizeof(float));
  return 1;
}

static int stub_rd_bytes(stub_reader *r, uint8_t *dst, int32_t len) {
  if (len < 0 || r->pos < 0 || r->pos + len > r->n) return 0;
  memcpy(dst, r->p + r->pos, (size_t)len);
  r->pos += len;
  return 1;
}

/* ---------------- dtype 工具 ---------------- */

static int32_t stub_dtype_size(int32_t dtype) {
  switch (dtype) {
    case 0: return 4; /* Float32 */
    case 1: return 2; /* Float16 */
    case 2: return 4; /* Int32 */
    case 3: return 1; /* UInt8 */
    case 4: return 1; /* Int8 */
    case 5: return 8; /* Int64 */
    default: return 0;
  }
}

static int32_t stub_elems_of(const stub_tmeta *t) {
  int32_t i;
  int64_t elems = 1;
  for (i = 0; i < t->rank; i++) elems *= t->dims[i];
  return (int32_t)elems;
}

/* ---------------- Float16 软件转换（确定性、就近舍入） ---------------- */

static float stub_f16_to_f32(uint16_t h) {
  uint32_t sign = ((uint32_t)h & 0x8000u) << 16;
  uint32_t exp = ((uint32_t)h >> 10) & 0x1Fu;
  uint32_t mant = (uint32_t)h & 0x3FFu;
  uint32_t x;
  float f;
  if (exp == 0) {
    if (mant == 0) {
      x = sign;
    } else {
      exp = 113; /* 127 - 15 + 1 */
      while ((mant & 0x400u) == 0) {
        mant <<= 1;
        exp--;
      }
      mant &= 0x3FFu;
      x = sign | (exp << 23) | (mant << 13);
    }
  } else if (exp == 31) {
    x = sign | 0x7F800000u | (mant << 13);
  } else {
    x = sign | ((exp + 127u - 15u) << 23) | (mant << 13);
  }
  memcpy(&f, &x, sizeof(float));
  return f;
}

static uint16_t stub_f32_to_f16(float f) {
  uint32_t x;
  uint32_t sign, mant;
  int32_t exp, e;
  memcpy(&x, &f, sizeof(float));
  sign = (x >> 16) & 0x8000u;
  exp = (int32_t)((x >> 23) & 0xFFu);
  mant = x & 0x7FFFFFu;
  if (exp == 255) {
    return (uint16_t)(sign | 0x7C00u | (mant ? 0x200u : 0u));
  }
  e = exp - 127 + 15;
  if (e >= 31) return (uint16_t)(sign | 0x7C00u); /* 溢出 -> inf */
  if (e <= 0) {
    uint32_t half, rem, halfbit;
    int32_t shift;
    if (e < -10) return (uint16_t)sign; /* 下溢 -> 0 */
    mant |= 0x800000u;
    shift = 14 - e;
    half = mant >> shift;
    rem = mant & ((1u << shift) - 1u);
    halfbit = 1u << (shift - 1);
    if (rem > halfbit || (rem == halfbit && (half & 1u))) half++;
    return (uint16_t)(sign | half);
  }
  {
    uint32_t half = ((uint32_t)e << 10) | (mant >> 13);
    uint32_t rem = mant & 0x1FFFu;
    if (rem > 0x1000u || (rem == 0x1000u && (half & 1u))) half++;
    return (uint16_t)(sign | half);
  }
}

/* ---------------- 张量描述解析 ---------------- */

static int stub_parse_tensor(stub_reader *r, stub_tmeta *t, int32_t is_output) {
  uint32_t name_len, dtype, rank;
  int32_t i;
  int64_t elems = 1;
  if (!stub_rd_u32(r, &name_len)) return 0;
  if (name_len < 1 || name_len > (uint32_t)STUB_MAX_NAME) return 0;
  t->name_len = (int32_t)name_len;
  if (!stub_rd_bytes(r, (uint8_t *)t->name, (int32_t)name_len)) return 0;
  t->name[name_len] = '\0';
  if (!stub_rd_u32(r, &dtype) || dtype > 5) return 0;
  t->dtype = (int32_t)dtype;
  if (!stub_rd_u32(r, &rank) || rank < 1 || rank > (uint32_t)STUB_MAX_RANK)
    return 0;
  t->rank = (int32_t)rank;
  for (i = 0; i < t->rank; i++) {
    int32_t d;
    if (!stub_rd_i32(r, &d)) return 0;
    if (d < 1) {
      if (!(is_output && d == -1)) return 0;
    } else {
      if (d > STUB_MAX_ELEMS) return 0;
      elems *= d;
      if (elems > STUB_MAX_ELEMS) return 0;
    }
    t->template_dims[i] = d;
    t->dims[i] = d;
  }
  if (!stub_rd_f32(r, &t->qscale)) return 0;
  if (!stub_rd_i32(r, &t->qzero)) return 0;
  return 1;
}

/* 解析动态尺寸：-1 镜像 in0 的同轴尺寸；in0 为 NULL 时不允许 -1。 */
static int stub_resolve_tensor(const stub_tmeta *in0, stub_tmeta *t) {
  int32_t i;
  int64_t elems = 1;
  for (i = 0; i < t->rank; i++) {
    int32_t d = t->template_dims[i];
    if (d < 0) {
      if (in0 == NULL || i >= in0->rank) return 0;
      d = in0->dims[i];
    }
    t->dims[i] = d;
    elems *= d;
    if (elems > STUB_MAX_ELEMS) return 0;
  }
  t->byte_size = (int32_t)(elems * stub_dtype_size(t->dtype));
  return 1;
}

/* ---------------- 数值读写（按 dtype 解释） ---------------- */

static double stub_read_value(const uint8_t *buf, int32_t dtype, int32_t k) {
  switch (dtype) {
    case 0: {
      float f;
      memcpy(&f, buf + (size_t)k * 4, sizeof(float));
      return (double)f;
    }
    case 1: {
      uint16_t h;
      memcpy(&h, buf + (size_t)k * 2, sizeof(uint16_t));
      return (double)stub_f16_to_f32(h);
    }
    case 2: {
      int32_t v;
      memcpy(&v, buf + (size_t)k * 4, sizeof(int32_t));
      return (double)v;
    }
    case 3:
      return (double)buf[k];
    case 4:
      return (double)(int8_t)buf[k];
    case 5: {
      int64_t v;
      memcpy(&v, buf + (size_t)k * 8, sizeof(int64_t));
      return (double)v;
    }
    default:
      return 0.0;
  }
}

static double stub_trunc_toward_zero(double v) {
  if (!(v > -9.2e18 && v < 9.2e18)) return v; /* 饱和在写入端处理 */
  return (double)(int64_t)v;
}

static void stub_write_value(uint8_t *buf, int32_t dtype, int32_t k, double v) {
  switch (dtype) {
    case 0: {
      float f = (float)v;
      memcpy(buf + (size_t)k * 4, &f, sizeof(float));
      break;
    }
    case 1: {
      uint16_t h = stub_f32_to_f16((float)v);
      memcpy(buf + (size_t)k * 2, &h, sizeof(uint16_t));
      break;
    }
    case 2: {
      int32_t iv;
      double t = stub_trunc_toward_zero(v);
      if (!(t > -2147483648.0)) {
        iv = (-2147483647 - 1);
      } else if (!(t < 2147483647.0)) {
        iv = 2147483647;
      } else {
        iv = (int32_t)t;
      }
      memcpy(buf + (size_t)k * 4, &iv, sizeof(int32_t));
      break;
    }
    case 3: {
      double t = stub_trunc_toward_zero(v);
      uint8_t b;
      if (!(t > 0.0)) {
        b = 0;
      } else if (!(t < 255.0)) {
        b = 255;
      } else {
        b = (uint8_t)t;
      }
      buf[k] = b;
      break;
    }
    case 4: {
      double t = stub_trunc_toward_zero(v);
      int8_t b;
      if (!(t > -128.0)) {
        b = -128;
      } else if (!(t < 127.0)) {
        b = 127;
      } else {
        b = (int8_t)t;
      }
      buf[k] = (uint8_t)b;
      break;
    }
    case 5: {
      int64_t iv;
      double t = stub_trunc_toward_zero(v);
      if (!(t > -9223372036854775808.0)) {
        iv = (-9223372036854775807LL - 1);
      } else if (!(t < 9223372036854775807.0)) {
        iv = 9223372036854775807LL;
      } else {
        iv = (int64_t)t;
      }
      memcpy(buf + (size_t)k * 8, &iv, sizeof(int64_t));
      break;
    }
    default:
      break;
  }
}

/* ---------------- interp 内部分配 ---------------- */

static void stub_free_bufs(stub_interp *it) {
  int32_t i;
  if (it->inputs != NULL) {
    for (i = 0; i < it->model->input_count; i++) {
      free(it->inputs[i].buf);
      it->inputs[i].buf = NULL;
    }
  }
  if (it->outputs != NULL) {
    for (i = 0; i < it->model->output_count; i++) {
      free(it->outputs[i].buf);
      it->outputs[i].buf = NULL;
    }
  }
  it->allocated = 0;
}

static int stub_interp_allocate(stub_interp *it) {
  int32_t i;
  stub_free_bufs(it);
  for (i = 0; i < it->model->input_count; i++) {
    if (!stub_resolve_tensor(NULL, &it->inputs[i].tm)) return 0;
  }
  for (i = 0; i < it->model->output_count; i++) {
    if (!stub_resolve_tensor(&it->inputs[0].tm, &it->outputs[i].tm)) return 0;
  }
  for (i = 0; i < it->model->input_count; i++) {
    it->inputs[i].buf =
        (uint8_t *)calloc((size_t)it->inputs[i].tm.byte_size, 1);
    if (it->inputs[i].buf == NULL) return 0;
  }
  for (i = 0; i < it->model->output_count; i++) {
    it->outputs[i].buf =
        (uint8_t *)calloc((size_t)it->outputs[i].tm.byte_size, 1);
    if (it->outputs[i].buf == NULL) return 0;
  }
  it->allocated = 1;
  return 1;
}

/* ================= mb_tfl_* shim（docs/API.md 17 个，包私有） ================= */

int32_t mb_tfl_stub_impl_capi_version(void) { return MB_TFL_STUB_CAPI_VERSION; }

void *mb_tfl_stub_impl_model_create(uint8_t *model_bytes, int32_t size) {
  stub_reader r;
  stub_model *m;
  uint32_t u;
  int32_t i, total;
  if (model_bytes == NULL || size < 20) return NULL;
  if (model_bytes[0] != 'S' || model_bytes[1] != 'T' || model_bytes[2] != 'F' ||
      model_bytes[3] != '1')
    return NULL;
  r.p = model_bytes;
  r.n = size;
  r.pos = 4;
  if (!stub_rd_u32(&r, &u) || u != 1) return NULL; /* version */
  m = (stub_model *)calloc(1, sizeof(stub_model));
  if (m == NULL) return NULL;
  if (!stub_rd_u32(&r, &u) || u < 1 || u > STUB_MAX_TENSORS) goto fail;
  m->input_count = (int32_t)u;
  if (!stub_rd_u32(&r, &u) || u < 1 || u > STUB_MAX_TENSORS) goto fail;
  m->output_count = (int32_t)u;
  if (!stub_rd_f32(&r, &m->scale)) goto fail;
  total = m->input_count + m->output_count;
  m->inputs =
      (stub_tmeta *)calloc((size_t)m->input_count, sizeof(stub_tmeta));
  m->outputs =
      (stub_tmeta *)calloc((size_t)m->output_count, sizeof(stub_tmeta));
  if (m->inputs == NULL || m->outputs == NULL) goto fail;
  for (i = 0; i < total; i++) {
    stub_tmeta *t = (i < m->input_count) ? &m->inputs[i]
                                         : &m->outputs[i - m->input_count];
    if (!stub_parse_tensor(&r, t, i >= m->input_count)) goto fail;
  }
  if (r.pos != r.n) goto fail; /* 不允许尾随字节 */
  for (i = 0; i < m->input_count; i++) {
    if (!stub_resolve_tensor(NULL, &m->inputs[i])) goto fail;
  }
  for (i = 0; i < m->output_count; i++) {
    if (!stub_resolve_tensor(&m->inputs[0], &m->outputs[i])) goto fail;
  }
  return m;
fail:
  free(m->inputs);
  free(m->outputs);
  free(m);
  return NULL;
}

void mb_tfl_stub_impl_model_delete(void *model) {
  stub_model *m = (stub_model *)model;
  if (m == NULL) return;
  free(m->inputs);
  free(m->outputs);
  free(m);
}

void *mb_tfl_stub_impl_options_create(void) {
  stub_options *o = (stub_options *)calloc(1, sizeof(stub_options));
  return o;
}

void mb_tfl_stub_impl_options_set_threads(void *options, int32_t n) {
  stub_options *o = (stub_options *)options;
  if (o == NULL) return;
  if (n >= 1) {
    o->threads = n;
    o->threads_set = 1;
  }
}

void mb_tfl_stub_impl_options_delete(void *options) { free(options); }

void *mb_tfl_stub_impl_interpreter_create(void *model, void *options) {
  stub_model *m = (stub_model *)model;
  stub_options *o = (stub_options *)options;
  stub_interp *it;
  int32_t i;
  if (m == NULL || o == NULL || !o->threads_set) return NULL;
  it = (stub_interp *)calloc(1, sizeof(stub_interp));
  if (it == NULL) return NULL;
  it->model = m;
  it->inputs = (stub_tensor *)calloc((size_t)m->input_count, sizeof(stub_tensor));
  it->outputs =
      (stub_tensor *)calloc((size_t)m->output_count, sizeof(stub_tensor));
  if (it->inputs == NULL || it->outputs == NULL) goto fail;
  for (i = 0; i < m->input_count; i++) it->inputs[i].tm = m->inputs[i];
  for (i = 0; i < m->output_count; i++) it->outputs[i].tm = m->outputs[i];
  if (!stub_interp_allocate(it)) goto fail;
  return it;
fail:
  stub_free_bufs(it);
  free(it->inputs);
  free(it->outputs);
  free(it);
  return NULL;
}

void mb_tfl_stub_impl_interpreter_delete(void *interp) {
  stub_interp *it = (stub_interp *)interp;
  if (it == NULL) return;
  stub_free_bufs(it);
  free(it->inputs);
  free(it->outputs);
  free(it);
}

int32_t mb_tfl_stub_impl_input_count(void *interp) {
  stub_interp *it = (stub_interp *)interp;
  return it != NULL ? it->model->input_count : -1;
}

int32_t mb_tfl_stub_impl_output_count(void *interp) {
  stub_interp *it = (stub_interp *)interp;
  return it != NULL ? it->model->output_count : -1;
}

void *mb_tfl_stub_impl_input_tensor(void *interp, int32_t index) {
  stub_interp *it = (stub_interp *)interp;
  if (it == NULL || index < 0 || index >= it->model->input_count) return NULL;
  return &it->inputs[index];
}

void *mb_tfl_stub_impl_output_tensor(void *interp, int32_t index) {
  stub_interp *it = (stub_interp *)interp;
  if (it == NULL || index < 0 || index >= it->model->output_count) return NULL;
  return &it->outputs[index];
}

int32_t mb_tfl_stub_impl_resize_input(void *interp, int32_t index, int32_t *dims,
                            int32_t dims_len) {
  stub_interp *it = (stub_interp *)interp;
  stub_tensor *t;
  int32_t k;
  int64_t elems = 1;
  if (it == NULL || dims == NULL) return STUB_ERR;
  if (index < 0 || index >= it->model->input_count) return STUB_ERR;
  if (dims_len < 1 || dims_len > STUB_MAX_RANK) return STUB_ERR;
  for (k = 0; k < dims_len; k++) {
    if (dims[k] < 1 || dims[k] > STUB_MAX_ELEMS) return STUB_ERR;
    elems *= dims[k];
    if (elems > STUB_MAX_ELEMS) return STUB_ERR;
  }
  t = &it->inputs[index];
  t->tm.rank = dims_len;
  for (k = 0; k < dims_len; k++) {
    t->tm.template_dims[k] = dims[k];
    t->tm.dims[k] = dims[k];
  }
  t->tm.byte_size = (int32_t)(elems * stub_dtype_size(t->tm.dtype));
  /* 全部张量缓冲失效，需重新 allocate_tensors */
  stub_free_bufs(it);
  return STUB_OK;
}

int32_t mb_tfl_stub_impl_allocate_tensors(void *interp) {
  stub_interp *it = (stub_interp *)interp;
  if (it == NULL) return STUB_ERR;
  return stub_interp_allocate(it) ? STUB_OK : STUB_ERR;
}

int32_t mb_tfl_stub_impl_tensor_copy_from(void *tensor, uint8_t *src, int32_t size) {
  stub_tensor *t = (stub_tensor *)tensor;
  if (t == NULL || src == NULL || size < 0) return STUB_ERR;
  if (t->buf == NULL) return STUB_NOT_ALLOCATED;
  if (size != t->tm.byte_size) return STUB_ERR;
  memcpy(t->buf, src, (size_t)size);
  return STUB_OK;
}

int32_t mb_tfl_stub_impl_tensor_copy_to(void *tensor, uint8_t *dst, int32_t size) {
  stub_tensor *t = (stub_tensor *)tensor;
  if (t == NULL || dst == NULL || size < 0) return STUB_ERR;
  if (t->buf == NULL) return STUB_NOT_ALLOCATED;
  if (size != t->tm.byte_size) return STUB_ERR;
  memcpy(dst, t->buf, (size_t)size);
  return STUB_OK;
}

int32_t mb_tfl_stub_impl_invoke(void *interp) {
  stub_interp *it = (stub_interp *)interp;
  int32_t j, k, n, src_elems, dst_elems;
  if (it == NULL) return STUB_ERR;
  if (!it->allocated) return STUB_NOT_ALLOCATED;
  for (j = 0; j < it->model->output_count; j++) {
    stub_tensor *src = &it->inputs[j % it->model->input_count];
    stub_tensor *dst = &it->outputs[j];
    src_elems = stub_elems_of(&src->tm);
    dst_elems = stub_elems_of(&dst->tm);
    n = (src_elems < dst_elems) ? src_elems : dst_elems;
    for (k = 0; k < n; k++) {
      double v = stub_read_value(src->buf, src->tm.dtype, k);
      stub_write_value(dst->buf, dst->tm.dtype, k, (double)it->model->scale * v);
    }
    if (n < dst_elems) {
      memset(dst->buf + (size_t)n * stub_dtype_size(dst->tm.dtype), 0,
             (size_t)(dst_elems - n) * (size_t)stub_dtype_size(dst->tm.dtype));
    }
  }
  return STUB_OK;
}

/* ================= 私有符号（MoonBit 层内部 ABI） ================= */

int32_t mb_tfl_stub_impl_model_alive(void *h) { return h != NULL; }

int32_t mb_tfl_stub_impl_options_alive(void *h) { return h != NULL; }

int32_t mb_tfl_stub_impl_interp_alive(void *h) { return h != NULL; }

int32_t mb_tfl_stub_impl_tensor_meta(void *interp, int32_t index,
                                       int32_t is_output, int32_t *dims,
                                       int32_t *misc, double *qscale,
                                       uint8_t *name) {
  stub_interp *it = (stub_interp *)interp;
  stub_tmeta *t;
  int32_t k;
  if (it == NULL || dims == NULL || misc == NULL || qscale == NULL ||
      name == NULL)
    return STUB_ERR;
  if (is_output != 0 && is_output != 1) return STUB_ERR;
  if (is_output) {
    if (index < 0 || index >= it->model->output_count) return STUB_ERR;
    t = &it->outputs[index].tm;
  } else {
    if (index < 0 || index >= it->model->input_count) return STUB_ERR;
    t = &it->inputs[index].tm;
  }
  dims[0] = t->rank;
  for (k = 0; k < STUB_MAX_RANK; k++)
    dims[1 + k] = (k < t->rank) ? t->dims[k] : 0;
  misc[0] = t->dtype;
  misc[1] = t->byte_size;
  misc[2] = t->qzero;
  misc[3] = t->name_len;
  qscale[0] = (double)t->qscale;
  for (k = 0; k <= STUB_MAX_NAME; k++) name[k] = 0;
  memcpy(name, t->name, (size_t)t->name_len);
  return STUB_OK;
}
