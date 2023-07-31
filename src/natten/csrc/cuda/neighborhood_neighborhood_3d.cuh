/***************************************************************************************************
 * Copyright (c) 2023 Ali Hassani.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 **************************************************************************************************/
/*! \file
    \brief Neighborhood-Neighborhood kernel for 3D data.
           Applies neighborhood attention weights to neighborhood values.
*/

#include <torch/extension.h>

#include <cuda.h>
#include <cuda_runtime.h>
#include <vector>
#include <ATen/cuda/CUDAContext.h>
#include <ATen/ATen.h>
#include <ATen/native/cuda/KernelUtils.cuh>
#include <ATen/AccumulateType.h>
#include <cuda_fp16.h>

#include "cuda/natten_commons.cuh"

namespace natten {

template<class scalar_t>
using Tensor6D = typename torch::PackedTensorAccessor32<scalar_t,6,torch::DefaultPtrTraits>;

template <int KERNEL_SIZE, int KERNEL_SIZE_D, int NEIGHBORHOOD_SIZE, int NEIGHBORHOOD_SIZE_D, typename scalar_t>
__global__ void neighborhood_neighborhood_3d(           // AV     / Q-grad
    const Tensor6D<scalar_t> weights,                   // attn   / d_attn
    const Tensor6D<scalar_t> values,                    // value  / key
    Tensor6D<scalar_t> output,                          // output / d_query
    const int depth,
    const int height,
    const int width,
    const int heads,
    const int dilation,
    const int dilation_d,
    const int dim,
    const int totalElements) {
    const int linearIndex = blockIdx.x * blockDim.x + threadIdx.x;
    if (linearIndex < totalElements){
        int indtmp1 = linearIndex/dim;
        const int d = linearIndex - indtmp1 * dim;
        int indtmp2 = indtmp1/width;
        const int j = indtmp1 - indtmp2 * width;
        indtmp1 = indtmp2;
        indtmp2 = indtmp1/height;
        const int i = indtmp1 - indtmp2 * height;
        indtmp1 = indtmp2;
        indtmp2 = indtmp1/depth;
        const int k = indtmp1 - indtmp2 * depth;
        indtmp1 = indtmp2;
        indtmp2 = indtmp1/heads;
        const int h = indtmp1 - indtmp2 * heads;
        const int b = indtmp2;

        const int ni = get_window_start(i, height, KERNEL_SIZE, NEIGHBORHOOD_SIZE, dilation);
        const int nj = get_window_start(j, width, KERNEL_SIZE, NEIGHBORHOOD_SIZE, dilation);
        const int nk = get_window_start(k, depth, KERNEL_SIZE_D, NEIGHBORHOOD_SIZE_D, dilation_d);
        scalar_t updt = scalar_t(0);
        int weightsOffset = b * weights.stride(0) + h * weights.stride(1) + k * weights.stride(2) + i * weights.stride(3) + j * weights.stride(4);
        const int valuesOffset = b * values.stride(0) + h * values.stride(1) + d;
        #pragma unroll
        for (int xk=nk; xk < nk + KERNEL_SIZE_D * dilation_d; xk+=dilation_d)
            #pragma unroll
            for (int xi=ni; xi < ni + KERNEL_SIZE * dilation; xi+=dilation)
                #pragma unroll
                for (int xj=nj; xj < nj + KERNEL_SIZE * dilation; xj+=dilation){
                    const int valuesIndex = valuesOffset + xk * values.stride(2)  + xi * values.stride(3) + xj * values.stride(4);
                    updt += weights.data()[weightsOffset] * values.data()[valuesIndex];
                    ++weightsOffset;
                }
        output.data()[linearIndex] = updt;
    }
}

template <int KERNEL_SIZE, int KERNEL_SIZE_D, int NEIGHBORHOOD_SIZE, int NEIGHBORHOOD_SIZE_D, typename scalar_t>
__global__ void neighborhood_neighborhood_3d_fp16(      // AV     / Q-grad
    const Tensor6D<scalar_t> weights,                   // attn   / d_attn
    const Tensor6D<scalar_t> values,                    // value  / key
    Tensor6D<scalar_t> output,                          // output / d_query
    const int depth,
    const int height,
    const int width,
    const int heads,
    const int dilation,
    const int dilation_d,
    const int dimhalf,
    const int totalElements) {
    const int linearIndex = blockIdx.x * blockDim.x + threadIdx.x;
    if (linearIndex < totalElements){
        __half2* values2 = reinterpret_cast<__half2*>(values.data());
        __half2* output2 = reinterpret_cast<__half2*>(output.data());
        int indtmp1 = linearIndex/dimhalf;
        const int d = linearIndex - indtmp1 * dimhalf;
        int indtmp2 = indtmp1/width;
        const int j = indtmp1 - indtmp2 * width;
        indtmp1 = indtmp2;
        indtmp2 = indtmp1/height;
        const int i = indtmp1 - indtmp2 * height;
        indtmp1 = indtmp2;
        indtmp2 = indtmp1/depth;
        const int k = indtmp1 - indtmp2 * depth;
        indtmp1 = indtmp2;
        indtmp2 = indtmp1/heads;
        const int h = indtmp1 - indtmp2 * heads;
        const int b = indtmp2;

        const int ni = get_window_start(i, height, KERNEL_SIZE, NEIGHBORHOOD_SIZE, dilation);
        const int nj = get_window_start(j, width, KERNEL_SIZE, NEIGHBORHOOD_SIZE, dilation);
        const int nk = get_window_start(k, depth, KERNEL_SIZE_D, NEIGHBORHOOD_SIZE_D, dilation_d);
        __half2 updt = __float2half2_rn(0.f);
        int weightsOffset = b * weights.stride(0) + h * weights.stride(1) + k * weights.stride(2) + i * weights.stride(3) + j * weights.stride(4);
        const int stride3 = dimhalf * width;
        const int stride2 = stride3 * height;
        const int valuesOffset = b * (stride2 * depth * heads) + h * (stride2 * depth) + d;
        #pragma unroll
        for (int xk=nk; xk < nk + KERNEL_SIZE_D * dilation_d; xk+=dilation_d)
            #pragma unroll
            for (int xi=ni; xi < ni + KERNEL_SIZE * dilation; xi+=dilation)
                #pragma unroll
                for (int xj=nj; xj < nj + KERNEL_SIZE * dilation; xj+=dilation){
                    const int valuesIndex = valuesOffset + xk * stride2 + xi * stride3 + xj * dimhalf;
                    scalar_t a = weights.data()[weightsOffset];
                    updt = __hfma2(__halves2half2(a, a), values2[valuesIndex], updt);
                    ++weightsOffset;
                }
        output2[linearIndex] = updt;
    }
}

} // namespace natten