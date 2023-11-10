#include <torch/extension.h>

void silu_and_mul(
  torch::Tensor& out,
  torch::Tensor& input);

void gelu_new(
  torch::Tensor& out,
  torch::Tensor& input);

void gelu_fast(
  torch::Tensor& out,
  torch::Tensor& input);

void invoke_dequant_silu_and_mul_quant(
  torch::Tensor &out, torch::Tensor &input,
  const float scale_gate,
  const float scale_up,
  const float scale_out);

PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
  m.def(
    "silu_and_mul",
    &silu_and_mul,
    "Activation function used in SwiGLU.");
  m.def(
    "gelu_new",
    &gelu_new,
    "GELU implementation used in GPT-2.");
  m.def(
    "gelu_fast",
    &gelu_fast,
    "Approximate GELU implementation.");
  m.def(
    "invoke_dequant_silu_and_mul_quant",
    &invoke_dequant_silu_and_mul_quant,
    "Dequant input, apply silu and act and quant output.");
}