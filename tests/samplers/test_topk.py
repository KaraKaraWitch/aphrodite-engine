from typing import List
import pytest
import torch
from aphrodite import topk
import random

batch_size = 20
vocab_size = 32000
test_cnt = 10
TOPK_TEST = [[random.randint(1, 100) for _ in range(batch_size)]
             for _ in range(test_cnt)]
TOPS_TEST = [[random.uniform(0.0, 1.0) for _ in range(batch_size)]
             for _ in range(test_cnt)]
TOPA_TEST = [[random.uniform(0.0, 3.0) for _ in range(batch_size)]
             for _ in range(test_cnt)]
INPUTS_TEST = [torch.randn(batch_size, vocab_size, device="cuda:0")]


def _apply_top_a_top_p_top_k_with_new_kernel(
    logits: torch.Tensor,
    top_ps: List[float],
    top_ks: List[int],
    top_as: List[float],
) -> torch.Tensor:
    do_top_p = True
    do_top_k = True
    do_top_a = True
    softmax_res = logits.softmax(dim=-1)
    logit_dst = torch.full(logits.shape, -float("inf"), device=logits.device)
    max_top_k = 0
    if top_ps:
        p = torch.tensor(top_ps, dtype=logits.dtype, device=logits.device)
    if top_as:
        a = torch.tensor(top_as, dtype=logits.dtype, device=logits.device)
    else:
        a = torch.Tensor()
        p = torch.Tensor()
        do_top_p = False
        do_top_a = False

    if top_ks:
        max_top_k = max(top_ks)
        k = torch.tensor(top_ks, dtype=torch.int32, device=logits.device)
    else:
        k = torch.Tensor()
        do_top_k = False
    topk.top_k(logits, softmax_res, logit_dst, do_top_k, max_top_k, k,
               do_top_p, p, do_top_a, a)
    return logit_dst


def _apply_top_a_top_p_top_k(
    logits: torch.Tensor,
    top_ps: List[float],
    top_ks: List[int],
    top_as: List[float],
) -> torch.Tensor:

    p = torch.tensor(top_ps, dtype=logits.dtype, device=logits.device)
    k = torch.tensor(top_ks, dtype=torch.int, device=logits.device)
    a = torch.tensor(top_as, dtype=logits.dtype, device=logits.device)
    logits_sort, logits_idx = logits.sort(dim=-1, descending=True)

    # # Apply top-p and top-a
    # probs_sort = logits_sort.softmax(dim=-1)
    # probs_sum = probs_sort.cumsum(dim=-1)
    # top_p_mask = (probs_sum - probs_sort) > p.unsqueeze(dim=1)
    # # Calculate dynamic threshold for top-a
    # top_a_threshold = a.unsqueeze(dim=1) * probs_sort * probs_sort
    # top_a_mask = probs_sort > top_a_threshold
    # # Combine top-p and top-a masks
    # combined_mask = top_p_mask | top_a_mask
    # # Apply combined mask
    # logits_sort[combined_mask] = -float("inf")

    # Apply top-p and top-a.
    probs_sort = logits_sort.softmax(dim=-1)
    probs_sum = probs_sort.cumsum(dim=-1)
    top_a_thresholds = torch.pow(probs_sort[:, 0], 2) * a
    top_ap_mask = (probs_sort < top_a_thresholds.unsqueeze(1))  # Cull logits below the top-a threshold
    top_ap_mask.logical_or_(probs_sum > p.unsqueeze(dim=1))  # Cull logits above the top-p summation threshold
    top_ap_mask[:, 0] = False  # Guarantee at least one token is pickable
    logits_sort[top_ap_mask] = -float("inf")

    # Apply top-k.
    # Create a mask for the top-k elements.
    top_k_mask = torch.arange(logits_idx.shape[-1], device=logits_idx.device)
    top_k_mask = top_k_mask.expand(logits_idx.shape[0], -1)
    top_k_mask = top_k_mask >= k.unsqueeze(dim=1)
    logits_sort[top_k_mask] = -float("inf")

    # Re-sort the probabilities.
    logits = torch.gather(logits_sort,
                          dim=-1,
                          index=torch.argsort(logits_idx, dim=-1))
    return logits


@pytest.mark.parametrize("inputs", INPUTS_TEST)
@pytest.mark.parametrize("topps", TOPS_TEST)
@pytest.mark.parametrize("topks", TOPK_TEST)
@pytest.mark.parametrize("topas", TOPA_TEST)
def test_topk_kernel(inputs, topps, topks, topas):
    res1 = _apply_top_a_top_p_top_k_with_new_kernel(inputs, topps, topks, topas)
    res2 = _apply_top_a_top_p_top_k(inputs, topps, topks, topas)
    assert torch.allclose(res1, res2)


if __name__ == "__main__":
    start = torch.cuda.Event(enable_timing=True)
    end = torch.cuda.Event(enable_timing=True)
    start.record()
    pre = torch.cuda.max_memory_allocated(device="cuda:0")
    _apply_top_a_top_p_top_k_with_new_kernel(INPUTS_TEST[0], TOPS_TEST[0],
                                       TOPK_TEST[0], TOPA_TEST[0])
    aft = torch.cuda.max_memory_allocated(device="cuda:0")
    end.record()
    torch.cuda.synchronize()

    print(f"time cost of new kernel is {start.elapsed_time(end)/1000}s")
    print(f"memory cost of new kernel cost is {aft-pre}")

    start = torch.cuda.Event(enable_timing=True)
    end = torch.cuda.Event(enable_timing=True)

    start.record()
    pre = torch.cuda.max_memory_allocated(device="cuda:0")
    _apply_top_a_top_p_top_k(INPUTS_TEST[0], TOPS_TEST[0], TOPK_TEST[0],
                             TOPA_TEST[0])
    aft = torch.cuda.max_memory_allocated(device="cuda:0")
    end.record()
    torch.cuda.synchronize()
    print(f"time cost of old kernel is {start.elapsed_time(end)/1000}s")
    print(f"memory cost of old kernel cost is {aft-pre}")