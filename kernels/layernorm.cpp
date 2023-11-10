#include <torch/extension.h>

void rms_norm(torch::Tensor &out, torch::Tensor &input, torch::Tensor &weight,
              float epsilon);

void invoke_rms_norm_quant(torch::Tensor &out,   // [num_tokens, hidden_size]
                           torch::Tensor &input, // [num_tokens, hidden_size]
                           torch::Tensor &gamma, // [hidden_size]
                           float epsilon);

void invoke_dequant_add_residual_rms_norm_quant(
    torch::Tensor &out,      // [num_tokens, hidden_size]
    torch::Tensor &input,    // [num_tokens, hidden_size]
    torch::Tensor &residual, // [num_tokens, hidden_size]
    torch::Tensor &gamma,    // [hidden_size]
    float epsilon, float scale);

PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
  m.def("rms_norm", &rms_norm,
        "Apply Root Mean Square (RMS) Normalization to the input tensor.");
  m.def("invoke_rms_norm_quant", &invoke_rms_norm_quant,
        "Apply Root Mean Square (RMS) Normalization to the input tensor and "
        "quant output.");
  m.def("invoke_dequant_add_residual_rms_norm_quant",
        &invoke_dequant_add_residual_rms_norm_quant,
        "Add the dequanted result and residual, then use RMS norm and quant "
        "output.");
}