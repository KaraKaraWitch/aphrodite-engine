#include <torch/extension.h>
#include <ATen/cuda/CUDAContext.h>
#include "dispatch_utils.h"
namespace aphrodite {
template<typename scalar_t, bool IS_NEOX>
inline __device__ void apply_rotary_embedding(
  scalar_t* __restrict__ arr,
  const scalar_t* __restrict__ cos_ptr,
  const scalar_t* __restrict__ sin_ptr,
  int rot_offset,
  int embed_dim)
{
  int x_index, y_index;
  scalar_t cos, sin;
  if (IS_NEOX) {
    // GPT-NeoX style rotary embedding.
    x_index = rot_offset;
    y_index = embed_dim + rot_offset;
    cos = __ldg(cos_ptr + x_index);
    sin = __ldg(sin_ptr + x_index);
  } else {
    // GPT-J style rotary embedding.
    x_index = 2 * rot_offset;
    y_index = 2 * rot_offset + 1;
    cos = __ldg(cos_ptr + x_index / 2);
    sin = __ldg(sin_ptr + x_index / 2);
  }
  const scalar_t x = arr[x_index];
  const scalar_t y = arr[y_index];
  arr[x_index] = x * cos - y * sin;
  arr[y_index] = y * cos + x * sin;
}

template<typename scalar_t, bool IS_NEOX>
inline __device__ void apply_dequant_rotary_embedding(
  const int32_t* __restrict__ arr,
  scalar_t* __restrict__ arr_out,
  const scalar_t* __restrict__ cos_ptr,
  const scalar_t* __restrict__ sin_ptr,
  int rot_offset,
  int embed_dim,
  const float scale)
{
  int x_index, y_index;
  scalar_t cos, sin;
  if (IS_NEOX) {
    // GPT-NeoX style rotary embedding.
    x_index = rot_offset;
    y_index = embed_dim + rot_offset;
    cos = __ldg(cos_ptr + x_index);
    sin = __ldg(sin_ptr + x_index);
  } else {
    // GPT-J style rotary embedding.
    x_index = 2 * rot_offset;
    y_index = 2 * rot_offset + 1;
    cos = __ldg(cos_ptr + x_index / 2);
    sin = __ldg(sin_ptr + x_index / 2);
  }

  const scalar_t x = (scalar_t)((float)arr[x_index] * scale);
  const scalar_t y = (scalar_t)((float)arr[y_index] * scale);
  arr_out[x_index] = x * cos - y * sin;
  arr_out[y_index] = y * cos + x * sin;
}

template<typename scalar_t, bool IS_NEOX>
__global__ void rotary_embedding_kernel(
  const int64_t* __restrict__ positions,        // [batch_size, seq_len] or [num_tokens]
  scalar_t* __restrict__ query,                 // [batch_size, seq_len, num_heads, head_size] or [num_tokens, num_heads, head_size]
  scalar_t* __restrict__ key,                   // [batch_size, seq_len, num_kv_heads, head_size] or [num_tokens, num_kv_heads, head_size]
  const scalar_t* __restrict__ cos_sin_cache,   // [max_position, 2, rot_dim // 2]
  const int rot_dim,
  const int query_stride,
  const int key_stride,
  const int num_heads,
  const int num_kv_heads,
  const int head_size) {
  // Each thread block is responsible for one token.
  const int token_idx = blockIdx.x;
  int64_t pos = positions[token_idx];
  const scalar_t* cache_ptr = cos_sin_cache + pos * rot_dim;
  const int embed_dim = rot_dim / 2;
  const scalar_t* cos_ptr = cache_ptr;
  const scalar_t* sin_ptr = cache_ptr + embed_dim;
  const int nq = num_heads * embed_dim;
  for (int i = threadIdx.x; i < nq; i += blockDim.x) {
    const int head_idx = i / embed_dim;
    const int token_head = token_idx * query_stride + head_idx * head_size;
    const int rot_offset = i % embed_dim;
    apply_rotary_embedding<scalar_t, IS_NEOX>(query + token_head, cos_ptr,
                                              sin_ptr, rot_offset, embed_dim);
  }
  const int nk = num_kv_heads * embed_dim;
  for (int i = threadIdx.x; i < nk; i += blockDim.x) {
    const int head_idx = i / embed_dim;
    const int token_head = token_idx * key_stride + head_idx * head_size;
    const int rot_offset = i % embed_dim;
    apply_rotary_embedding<scalar_t, IS_NEOX>(key + token_head, cos_ptr,
                                              sin_ptr, rot_offset, embed_dim);
  }
}

template<typename scalar_t, bool IS_NEOX>
__global__ void dequant_rotary_embedding_kernel(
  const int64_t* __restrict__ positions,        // [num_tokens]
  const int32_t* __restrict__ query,                 // [num_tokens, num_heads, head_size]
  scalar_t* __restrict__ query_out,                 // [num_tokens, num_heads, head_size]
  const int32_t* __restrict__ key,                   // [num_tokens, num_kv_heads, head_size]
  scalar_t* __restrict__ key_out,                   // [num_tokens, num_kv_heads, head_size]
  const scalar_t* __restrict__ cos_sin_cache,   // [max_position, 2, rot_dim // 2]
  const int rot_dim,
  const int query_stride,
  const int query_out_stride,
  const int key_stride,
  const int key_out_stride,
  const int num_heads,
  const int num_kv_heads,
  const int head_size,
  const float query_scale,
  const float key_scale) {
  // Each thread block is responsible for one token.
  const int token_idx = blockIdx.x;
  int64_t pos = positions[token_idx];
  const scalar_t* cache_ptr = cos_sin_cache + pos * rot_dim;

  const int embed_dim = rot_dim / 2;
  const scalar_t* cos_ptr = cache_ptr;
  const scalar_t* sin_ptr = cache_ptr + embed_dim;

  const int nq = num_heads * embed_dim;
  for (int i = threadIdx.x; i < nq; i += blockDim.x) {
    const int head_idx = i / embed_dim;
    const int token_head = token_idx * query_stride + head_idx * head_size;
    const int token_out_head = token_idx * query_out_stride + head_idx * head_size;
    const int rot_offset = i % embed_dim;
    apply_dequant_rotary_embedding<scalar_t, IS_NEOX>(query + token_head, query_out + token_out_head, cos_ptr,
                                              sin_ptr, rot_offset, embed_dim, query_scale);
  }

  const int nk = num_kv_heads * embed_dim;
  for (int i = threadIdx.x; i < nk; i += blockDim.x) {
    const int head_idx = i / embed_dim;
    const int token_head = token_idx * key_stride + head_idx * head_size;
    const int token_out_head = token_idx * key_out_stride + head_idx * head_size;
    const int rot_offset = i % embed_dim;
    apply_dequant_rotary_embedding<scalar_t, IS_NEOX>(key + token_head, key_out + token_out_head, cos_ptr,
                                              sin_ptr, rot_offset, embed_dim, key_scale);
  }
}

} // namespace aphrodite

void rotary_embedding(
  torch::Tensor& positions,         // [batch_size, seq_len] or [num_tokens]
  torch::Tensor& query,             // [batch_size, seq_len, num_heads * head_size] or [num_tokens, num_heads * head_size]
  torch::Tensor& key,               // [batch_size, seq_len, num_kv_heads * head_size] or [num_tokens, num_kv_heads * head_size]
  int head_size,
  torch::Tensor& cos_sin_cache,     // [max_position, rot_dim]
  bool is_neox) {
  int num_tokens = query.numel() / query.size(-1);
  int rot_dim = cos_sin_cache.size(1);
  int num_heads = query.size(-1) / head_size;
  int num_kv_heads = key.size(-1) / head_size;
  int query_stride = query.stride(-2);
  int key_stride = key.stride(-2);
  dim3 grid(num_tokens);
  dim3 block(std::min(num_heads * rot_dim / 2, 512));
  const cudaStream_t stream = at::cuda::getCurrentCUDAStream();
  APHRODITE_DISPATCH_FLOATING_TYPES(
    query.scalar_type(),
    "rotary_embedding",
    [&] {
      if (is_neox) {
        aphrodite::rotary_embedding_kernel<scalar_t, true><<<grid, block, 0, stream>>>(
          positions.data_ptr<int64_t>(),
          query.data_ptr<scalar_t>(),
          key.data_ptr<scalar_t>(),
          cos_sin_cache.data_ptr<scalar_t>(),
          rot_dim,
          query_stride,
          key_stride,
          num_heads,
          num_kv_heads,
          head_size);
      } else {
        aphrodite::rotary_embedding_kernel<scalar_t, false><<<grid, block, 0, stream>>>(
          positions.data_ptr<int64_t>(),
          query.data_ptr<scalar_t>(),
          key.data_ptr<scalar_t>(),
          cos_sin_cache.data_ptr<scalar_t>(),
          rot_dim,
          query_stride,
          key_stride,
          num_heads,
          num_kv_heads,
          head_size);
      }
    });
}


void invoke_dequant_rotary_embedding(
  torch::Tensor& positions,         // [num_tokens]
  torch::Tensor& query,             // [num_tokens, num_heads * head_size]
  torch::Tensor& query_out,             // [num_tokens, num_heads * head_size]
  torch::Tensor& key,               // [num_tokens, num_kv_heads * head_size]
  torch::Tensor& key_out,               // [num_tokens, num_kv_heads * head_size]
  int head_size,
  torch::Tensor& cos_sin_cache,     // [max_position, rot_dim]
  const float query_scale,
  const float key_scale,
  bool is_neox) {
  int num_tokens = query.size(0);
  int rot_dim = cos_sin_cache.size(1);
  int num_heads = query.size(1) / head_size;
  int num_kv_heads = key.size(1) / head_size;
  int query_stride = query.stride(0);
  int key_stride = key.stride(0);
  int query_out_stride = query_out.stride(0);
  int key_out_stride = key_out.stride(0);
  dim3 grid(num_tokens);
  dim3 block(std::min(num_heads * rot_dim / 2, 512));
  const cudaStream_t stream = at::cuda::getCurrentCUDAStream();
  APHRODITE_DISPATCH_FLOATING_TYPES(
    query_out.scalar_type(),
    "dequant_rotary_embedding_kernel",
    [&] {
      if (is_neox) {
        aphrodite::dequant_rotary_embedding_kernel<scalar_t, true><<<grid, block, 0, stream>>>(
          positions.data_ptr<int64_t>(),
          query.data_ptr<int32_t>(),
          query_out.data_ptr<scalar_t>(),
          key.data_ptr<int32_t>(),
          key_out.data_ptr<scalar_t>(),
          cos_sin_cache.data_ptr<scalar_t>(),
          rot_dim,
          query_stride,
          query_out_stride,
          key_stride,
          key_out_stride,
          num_heads,
          num_kv_heads,
          head_size,
          query_scale,
          key_scale);
      } else {
        aphrodite::dequant_rotary_embedding_kernel<scalar_t, false><<<grid, block, 0, stream>>>(
          positions.data_ptr<int64_t>(),
          query.data_ptr<int32_t>(),
          query_out.data_ptr<scalar_t>(),
          key.data_ptr<int32_t>(),
          key_out.data_ptr<scalar_t>(),
          cos_sin_cache.data_ptr<scalar_t>(),
          rot_dim,
          query_stride,
          query_out_stride,
          key_stride,
          key_out_stride,
          num_heads,
          num_kv_heads,
          head_size,
          query_scale,
          key_scale);
      }
    });
}