#include "dfMatrixOpBase.H"
#include "dfMatrixDataBase.H"
#include "dfNcclBase.H"

#include <cuda_runtime.h>
#include "cuda_profiler_api.h"

#ifdef TIME_GPU
    #define TICK_INIT_EVENT \
        float time_elapsed_kernel=0;\
        cudaEvent_t start_kernel, stop_kernel;\
        checkCudaErrors(cudaEventCreate(&start_kernel));\
        checkCudaErrors(cudaEventCreate(&stop_kernel));

    #define TICK_START_EVENT \
        checkCudaErrors(cudaEventRecord(start_kernel,0));

    #define TICK_END_EVENT(prefix) \
        checkCudaErrors(cudaEventRecord(stop_kernel,0));\
        checkCudaErrors(cudaEventSynchronize(start_kernel));\
        checkCudaErrors(cudaEventSynchronize(stop_kernel));\
        checkCudaErrors(cudaEventElapsedTime(&time_elapsed_kernel,start_kernel,stop_kernel));\
        printf("try %s 执行时间：%lf(ms)\n", #prefix, time_elapsed_kernel);
#else
    #define TICK_INIT_EVENT
    #define TICK_START_EVENT
    #define TICK_END_EVENT(prefix)
#endif

__global__ void warmup(int num_cells)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_cells)
        return;
}

__global__ void permute_vector_d2h_kernel(int num_cells, const double *input, double *output)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_cells)
        return;

    output[index * 3 + 0] = input[num_cells * 0 + index];
    output[index * 3 + 1] = input[num_cells * 1 + index];
    output[index * 3 + 2] = input[num_cells * 2 + index];
}

__global__ void permute_vector_h2d_kernel(int num_cells, const double *input, double *output)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_cells)
        return;

    output[num_cells * 0 + index] = input[index * 3 + 0];
    output[num_cells * 1 + index] = input[index * 3 + 1];
    output[num_cells * 2 + index] = input[index * 3 + 2];
}

__global__ void field_add_scalar_kernel(int num_cells, int num_boundary_surfaces,
        const double *input1, const double *input2, double *output,
        const double *boundary_input1, const double *boundary_input2, double *boundary_output)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index < num_cells) {
        output[index] = input1[index] + input2[index];
    }
    if (index < num_boundary_surfaces) {
        boundary_output[index] = boundary_input1[index] + boundary_input2[index];
    }
}

__global__ void field_add_vector_kernel(int num_cells, int num_boundary_surfaces,
        const double *input1, const double *input2, double *output,
        const double *boundary_input1, const double *boundary_input2, double *boundary_output, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index < num_cells) {
        output[num_cells * 0 + index] = input1[num_cells * 0 + index] + input2[num_cells * 0 + index] * sign;
        output[num_cells * 1 + index] = input1[num_cells * 1 + index] + input2[num_cells * 1 + index] * sign;
        output[num_cells * 2 + index] = input1[num_cells * 2 + index] + input2[num_cells * 2 + index] * sign;
    }
    if (index < num_boundary_surfaces) {
        boundary_output[num_boundary_surfaces * 0 + index] = boundary_input1[num_boundary_surfaces * 0 + index] + boundary_input2[num_boundary_surfaces * 0 + index] * sign;
        boundary_output[num_boundary_surfaces * 1 + index] = boundary_input1[num_boundary_surfaces * 1 + index] + boundary_input2[num_boundary_surfaces * 1 + index] * sign;
        boundary_output[num_boundary_surfaces * 2 + index] = boundary_input1[num_boundary_surfaces * 2 + index] + boundary_input2[num_boundary_surfaces * 2 + index] * sign;
    }
}

__global__ void field_multiply_scalar_kernel(int num_cells, int num_boundary_surfaces,
        const double *input1, const double *input2, double *output,
        const double *boundary_input1, const double *boundary_input2, double *boundary_output)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index < num_cells) {
        output[index] = input1[index] * input2[index];
    }
    if (index < num_boundary_surfaces) {
        boundary_output[index] = boundary_input1[index] * boundary_input2[index];
    }
}

__global__ void scalar_multiply_vector_kernel(int num_cells, int num_boundary_surfaces,
        const double *scalar_input, const double *vector_input, double *output,
        const double *scalar_boundary_input, const double *vector_boundary_input, double *boundary_output)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index < num_cells) {
        output[num_cells * 0 + index] = scalar_input[index] * vector_input[num_cells * 0 + index];
        output[num_cells * 1 + index] = scalar_input[index] * vector_input[num_cells * 1 + index];
        output[num_cells * 2 + index] = scalar_input[index] * vector_input[num_cells * 2 + index];
    }
    if (index < num_boundary_surfaces) {
        boundary_output[num_boundary_surfaces * 0 + index] = scalar_boundary_input[index] * vector_boundary_input[num_boundary_surfaces * 0 + index];
        boundary_output[num_boundary_surfaces * 1 + index] = scalar_boundary_input[index] * vector_boundary_input[num_boundary_surfaces * 1 + index];
        boundary_output[num_boundary_surfaces * 2 + index] = scalar_boundary_input[index] * vector_boundary_input[num_boundary_surfaces * 2 + index];
    }
}

__global__ void fvc_to_source_vector_kernel(int num_cells, const double *volume, const double *fvc_output, double *source)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_cells)
        return;

    // source[index * 3 + 0] += fvc_output[index * 3 + 0] * volume[index];
    // source[index * 3 + 1] += fvc_output[index * 3 + 1] * volume[index];
    // source[index * 3 + 2] += fvc_output[index * 3 + 2] * volume[index];
    source[index * 3 + 0] += fvc_output[index * 3 + 0];
    source[index * 3 + 1] += fvc_output[index * 3 + 1];
    source[index * 3 + 2] += fvc_output[index * 3 + 2];
}

__global__ void fvc_to_source_scalar_kernel(int num_cells, const double *volume, const double *fvc_output, double *source, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_cells)
        return;

    source[index] += fvc_output[index] * volume[index] * sign;
}

__global__ void compute_upwind_weight_internal(int num_faces, const double *phi, double *weight)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_faces)
        return;
    if (phi[index] >= 0)
        weight[index] = 1.;
    else
        weight[index] = 0.;
}

__global__ void update_boundary_coeffs_zeroGradient_scalar(int num, int offset,
        double *value_internal_coeffs, double *value_boundary_coeffs,
        double *gradient_internal_coeffs, double *gradient_boundary_coeffs)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;

    int start_index = offset + index;
    // valueInternalCoeffs = 1
    // valueBoundaryCoeffs = 0
    // gradientInternalCoeffs = 0
    // gradientBoundaryCoeffs = 0
    value_internal_coeffs[start_index] = 1;
    value_boundary_coeffs[start_index] = 0;
    gradient_internal_coeffs[start_index] = 0;
    gradient_boundary_coeffs[start_index] = 0;
}

__global__ void correct_boundary_conditions_zeroGradient_scalar(int num, int offset,
        const double *vf_internal, const int *face2Cells, double *vf_boundary)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;

    int start_index = offset + index;

    int cellIndex = face2Cells[start_index];
    vf_boundary[start_index] = vf_internal[cellIndex];
}

__global__ void correct_internal_boundary_field(int num, int offset,
        const double *vf_internal, const int *face2Cells, double *vf_boundary)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;

    int neighbor_start_index = offset + index;
    int internal_start_index = offset + num + index;

    int cellIndex = face2Cells[neighbor_start_index];
    vf_boundary[internal_start_index] = vf_internal[cellIndex];
}

void correct_boundary_conditions_processor_scalar(cudaStream_t stream, ncclComm_t comm,
        int peer, int num, int offset, 
        const double *vf, const int *boundary_cell_face, double *vf_boundary)
{
    int neighbor_start_index = offset;
    int internal_start_index = offset + num;

    size_t threads_per_block = 32;
    size_t blocks_per_grid = (num + threads_per_block - 1) / threads_per_block;
    correct_internal_boundary_field<<<blocks_per_grid, threads_per_block, 0, stream>>>(num, offset, 
            vf, boundary_cell_face, vf_boundary);

    checkNcclErrors(ncclGroupStart());
    checkNcclErrors(ncclSend(vf_boundary + internal_start_index, num, ncclDouble, peer, comm, stream));
    checkNcclErrors(ncclRecv(vf_boundary + neighbor_start_index, num, ncclDouble, peer, comm, stream));
    checkNcclErrors(ncclGroupEnd());
    checkCudaErrors(cudaStreamSynchronize(stream));
}

__global__ void update_boundary_coeffs_fixedValue_scalar(int num, int offset,
        const double *boundary_vf, const double *boundary_deltaCoeffs, 
        double *value_internal_coeffs, double *value_boundary_coeffs,
        double *gradient_internal_coeffs, double *gradient_boundary_coeffs)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;

    int start_index = offset + index;
    value_internal_coeffs[start_index] = 0.;
    value_boundary_coeffs[start_index] = boundary_vf[start_index];
    gradient_internal_coeffs[start_index] = -1 * boundary_deltaCoeffs[start_index];
    gradient_boundary_coeffs[start_index] = boundary_vf[start_index] * boundary_deltaCoeffs[start_index];
}

__global__ void update_boundary_coeffs_gradientEnergy_scalar(int num, int offset,
        const double *gradient, const double *boundary_deltaCoeffs, 
        double *value_internal_coeffs, double *value_boundary_coeffs,
        double *gradient_internal_coeffs, double *gradient_boundary_coeffs)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;

    int start_index = offset + index;

    double grad = gradient[start_index];

    value_internal_coeffs[start_index] = 1.;
    value_boundary_coeffs[start_index] = grad / boundary_deltaCoeffs[start_index];
    gradient_internal_coeffs[start_index] = 0.;
    gradient_boundary_coeffs[start_index] = grad;
}

__global__ void update_boundary_coeffs_zeroGradient_vector(int num_boundary_surfaces, int num, int offset,
        double *value_internal_coeffs, double *value_boundary_coeffs,
        double *gradient_internal_coeffs, double *gradient_boundary_coeffs)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;

    int start_index = offset + index;
    // valueInternalCoeffs = 1
    // valueBoundaryCoeffs = 0
    // gradientInternalCoeffs = 0
    // gradientBoundaryCoeffs = 0
    value_internal_coeffs[num_boundary_surfaces * 0 + start_index] = 1;
    value_internal_coeffs[num_boundary_surfaces * 1 + start_index] = 1;
    value_internal_coeffs[num_boundary_surfaces * 2 + start_index] = 1;
    value_boundary_coeffs[num_boundary_surfaces * 0 + start_index] = 0;
    value_boundary_coeffs[num_boundary_surfaces * 1 + start_index] = 0;
    value_boundary_coeffs[num_boundary_surfaces * 2 + start_index] = 0;
    gradient_internal_coeffs[num_boundary_surfaces * 0 + start_index] = 0;
    gradient_internal_coeffs[num_boundary_surfaces * 1 + start_index] = 0;
    gradient_internal_coeffs[num_boundary_surfaces * 2 + start_index] = 0;
    gradient_boundary_coeffs[num_boundary_surfaces * 0 + start_index] = 0;
    gradient_boundary_coeffs[num_boundary_surfaces * 1 + start_index] = 0;
    gradient_boundary_coeffs[num_boundary_surfaces * 2 + start_index] = 0;
}

__global__ void update_boundary_coeffs_fixedValue_vector(int num_boundary_surfaces, int num, int offset,
        const double *boundary_vf, const double *boundary_deltaCoeffs, 
        double *value_internal_coeffs, double *value_boundary_coeffs,
        double *gradient_internal_coeffs, double *gradient_boundary_coeffs)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;

    int start_index = offset + index;
    double bouDeltaCoeffs = boundary_deltaCoeffs[start_index];

    value_internal_coeffs[num_boundary_surfaces * 0 + start_index] = 0.; // valueInternalCoeffs = 0.
    value_internal_coeffs[num_boundary_surfaces * 1 + start_index] = 0.;
    value_internal_coeffs[num_boundary_surfaces * 2 + start_index] = 0.;
    value_boundary_coeffs[num_boundary_surfaces * 0 + start_index] = boundary_vf[num_boundary_surfaces * 0 + start_index]; // valueBoundaryCoeffs = boundaryValue
    value_boundary_coeffs[num_boundary_surfaces * 1 + start_index] = boundary_vf[num_boundary_surfaces * 1 + start_index];
    value_boundary_coeffs[num_boundary_surfaces * 2 + start_index] = boundary_vf[num_boundary_surfaces * 2 + start_index];
    gradient_internal_coeffs[num_boundary_surfaces * 0 + start_index] = -1 * bouDeltaCoeffs; // gradientInternalCoeffs = -1 * boundaryDeltaCoeffs
    gradient_internal_coeffs[num_boundary_surfaces * 1 + start_index] = -1 * bouDeltaCoeffs;
    gradient_internal_coeffs[num_boundary_surfaces * 2 + start_index] = -1 * bouDeltaCoeffs;
    gradient_boundary_coeffs[num_boundary_surfaces * 0 + start_index] = bouDeltaCoeffs * boundary_vf[num_boundary_surfaces * 0 + start_index]; // gradientBoundaryCoeffs = boundaryDeltaCoeffs * boundaryValue
    gradient_boundary_coeffs[num_boundary_surfaces * 1 + start_index] = bouDeltaCoeffs * boundary_vf[num_boundary_surfaces * 1 + start_index];
    gradient_boundary_coeffs[num_boundary_surfaces * 2 + start_index] = bouDeltaCoeffs * boundary_vf[num_boundary_surfaces * 2 + start_index];
}

__global__ void update_boundary_coeffs_processor_vector(int num_boundary_surfaces, int num, int offset,
        const double *boundary_weight, const double *boundary_deltaCoeffs, 
        double *value_internal_coeffs, double *value_boundary_coeffs,
        double *gradient_internal_coeffs, double *gradient_boundary_coeffs)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;

    int start_index = offset + index;
    double bouWeight = boundary_weight[start_index];
    double bouDeltaCoeffs = boundary_deltaCoeffs[start_index];

    value_internal_coeffs[num_boundary_surfaces * 0 + start_index] = bouWeight; // valueInternalCoeffs = Type(pTraits<Type>::one)*w
    value_internal_coeffs[num_boundary_surfaces * 1 + start_index] = bouWeight;
    value_internal_coeffs[num_boundary_surfaces * 2 + start_index] = bouWeight;
    value_boundary_coeffs[num_boundary_surfaces * 0 + start_index] = 1 - bouWeight; // valueBoundaryCoeffs = Type(pTraits<Type>::one)*(1.0 - w)
    value_boundary_coeffs[num_boundary_surfaces * 1 + start_index] = 1 - bouWeight;
    value_boundary_coeffs[num_boundary_surfaces * 2 + start_index] = 1 - bouWeight;
    gradient_internal_coeffs[num_boundary_surfaces * 0 + start_index] = -1 * bouDeltaCoeffs; // gradientInternalCoeffs = -Type(pTraits<Type>::one)*deltaCoeffs
    gradient_internal_coeffs[num_boundary_surfaces * 1 + start_index] = -1 * bouDeltaCoeffs;
    gradient_internal_coeffs[num_boundary_surfaces * 2 + start_index] = -1 * bouDeltaCoeffs;
    gradient_boundary_coeffs[num_boundary_surfaces * 0 + start_index] = bouDeltaCoeffs; // gradientBoundaryCoeffs = -this->gradientInternalCoeffs(deltaCoeffs)
    gradient_boundary_coeffs[num_boundary_surfaces * 1 + start_index] = bouDeltaCoeffs;
    gradient_boundary_coeffs[num_boundary_surfaces * 2 + start_index] = bouDeltaCoeffs;
}

__global__ void scale_dev2t_tensor_kernel(int num, const double *vf1, double *vf2)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;

    double scale = vf1[index];
    double val_xx = vf2[num * 0 + index];
    double val_xy = vf2[num * 1 + index];
    double val_xz = vf2[num * 2 + index];
    double val_yx = vf2[num * 3 + index];
    double val_yy = vf2[num * 4 + index];
    double val_yz = vf2[num * 5 + index];
    double val_zx = vf2[num * 6 + index];
    double val_zy = vf2[num * 7 + index];
    double val_zz = vf2[num * 8 + index];
    double trace_coeff = (2. / 3.) * (val_xx + val_yy + val_zz);
    vf2[num * 0 + index] = scale * (val_xx - trace_coeff);
    vf2[num * 1 + index] = scale * val_yx;
    vf2[num * 2 + index] = scale * val_zx;
    vf2[num * 3 + index] = scale * val_xy;
    vf2[num * 4 + index] = scale * (val_yy - trace_coeff);
    vf2[num * 5 + index] = scale * val_zy;
    vf2[num * 6 + index] = scale * val_xz;
    vf2[num * 7 + index] = scale * val_yz;
    vf2[num * 8 + index] = scale * (val_zz - trace_coeff);

    // if (index == 0)
    // {
    //     printf("bou_grad_U = (%.5e, %.5e, %.5e, %.5e, %.5e, %.5e, %.5e, %.5e, %.5e)", vf2[0], vf2[1], vf2[2],
    //             vf2[3], vf2[4], vf2[5], vf2[6], vf2[7], vf2[8]);
    // }
    
}

__global__ void fvm_ddt_vol_scalar_vol_scalar_kernel(int num_cells, double rDeltaT,
        const double *rho, const double *rho_old, const double *vf, const double *volume,
        double *diag, double *source, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_cells)
        return;

    diag[index] += rDeltaT * rho[index] * volume[index] * sign;
    // TODO: skip moving
    source[index] += rDeltaT * rho_old[index] * vf[index] * volume[index] * sign;
}

__global__ void fvm_ddt_scalar_kernel(int num_cells, double rDeltaT,
        const double *vf_old, const double *volume, 
        double *diag, double *source, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_cells)
        return;
    
    double vol = volume[index];
    
    diag[index] += rDeltaT * vol * sign;
    source[index] += rDeltaT * vf_old[index] * vol * sign;
}

__global__ void fvm_ddt_vector_kernel(int num_cells, double rDeltaT,
        const double *rho, const double *rho_old, const double *vf, const double *volume,
        double *diag, double *source, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_cells)
        return;

    double vol = volume[index];
    double rho_old_kernel = rho_old[index];

    diag[index] += rDeltaT * rho[index] * vol * sign;
    // TODO: skip moving
    source[num_cells * 0 + index] += rDeltaT * rho_old_kernel * vf[num_cells * 0 + index] * vol * sign;
    source[num_cells * 1 + index] += rDeltaT * rho_old_kernel * vf[num_cells * 1 + index] * vol * sign;
    source[num_cells * 2 + index] += rDeltaT * rho_old_kernel * vf[num_cells * 2 + index] * vol * sign;    
}

// same with fvm_div_vector_internal
__global__ void fvm_div_scalar_internal(int num_surfaces,
        const int *lower_index, const int *upper_index,
        const double *phi, const double *weight,
        double *lower, double *upper, double *diag, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_surfaces)
        return;

    double w = weight[index];
    double f = phi[index];

    double lower_value = (-w) * f * sign;
    double upper_value = (1 - w) * f * sign;
    lower[index] += lower_value;
    upper[index] += upper_value;

    int owner = lower_index[index];
    int neighbor = upper_index[index];
    atomicAdd(&(diag[owner]), -lower_value);
    atomicAdd(&(diag[neighbor]), -upper_value);
}

__global__ void fvm_div_scalar_boundary(int num, int offset,
        const double *boundary_phi, const double *value_internal_coeffs, const double *value_boundary_coeffs,
        double *internal_coeffs, double *boundary_coeffs, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;

    int start_index = offset + index;
    double boundary_f = boundary_phi[start_index];
    internal_coeffs[start_index] += boundary_f * value_internal_coeffs[start_index] * sign;
    boundary_coeffs[start_index] -= boundary_f * value_boundary_coeffs[start_index] * sign;
}

__global__ void fvm_div_vector_internal(int num_surfaces,
        const int *lower_index, const int *upper_index,
        const double *phi, const double *weight,
        double *lower, double *upper, double *diag, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_surfaces)
        return;

    double w = weight[index];
    double f = phi[index];

    double lower_value = (-w) * f * sign;
    double upper_value = (1 - w) * f * sign;
    lower[index] += lower_value;
    upper[index] += upper_value;

    int owner = lower_index[index];
    int neighbor = upper_index[index];
    atomicAdd(&(diag[owner]), -lower_value);
    atomicAdd(&(diag[neighbor]), -upper_value);
}

// TODO: modify the data structure of internal and boundary coeffs
__global__ void fvm_div_vector_boundary(int num_boundary_surfaces, int num, int offset,
        const double *boundary_phi, const double *value_internal_coeffs, const double *value_boundary_coeffs,
        double *internal_coeffs, double *boundary_coeffs, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;

    int start_index = offset + index;
    double boundary_f = boundary_phi[start_index];
    internal_coeffs[num_boundary_surfaces * 0 + start_index] += boundary_f * value_internal_coeffs[num_boundary_surfaces * 0 + start_index] * sign;
    internal_coeffs[num_boundary_surfaces * 1 + start_index] += boundary_f * value_internal_coeffs[num_boundary_surfaces * 1 + start_index] * sign;
    internal_coeffs[num_boundary_surfaces * 2 + start_index] += boundary_f * value_internal_coeffs[num_boundary_surfaces * 2 + start_index] * sign;
    boundary_coeffs[num_boundary_surfaces * 0 + start_index] -= boundary_f * value_boundary_coeffs[num_boundary_surfaces * 0 + start_index] * sign;
    boundary_coeffs[num_boundary_surfaces * 1 + start_index] -= boundary_f * value_boundary_coeffs[num_boundary_surfaces * 1 + start_index] * sign;
    boundary_coeffs[num_boundary_surfaces * 2 + start_index] -= boundary_f * value_boundary_coeffs[num_boundary_surfaces * 2 + start_index] * sign;
}

__global__ void fvm_laplacian_internal(int num_surfaces,
        const int *lower_index, const int *upper_index,
        const double *weight, const double *mag_sf, const double *delta_coeffs, const double *gamma,
        double *lower, double *upper, double *diag, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_surfaces)
        return;

    int owner = lower_index[index];
    int neighbor = upper_index[index];

    double w = weight[index];
    double face_gamma = w * gamma[owner] + (1 - w) * gamma[neighbor];

    // for fvm::laplacian, lower = upper
    double upper_value = face_gamma * mag_sf[index] * delta_coeffs[index];
    double lower_value = upper_value;

    lower_value = lower_value * sign;
    upper_value = upper_value * sign;

    lower[index] += lower_value;
    upper[index] += upper_value;

    atomicAdd(&(diag[owner]), -lower_value);
    atomicAdd(&(diag[neighbor]), -upper_value);
}

__global__ void fvm_laplacian_surface_scalar_internal(int num_surfaces,
        const int *lower_index, const int *upper_index,
        const double *mag_sf, const double *delta_coeffs, const double *gamma,
        double *lower, double *upper, double *diag, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_surfaces)
        return;

    int owner = lower_index[index];
    int neighbor = upper_index[index];

    double face_gamma = gamma[index];

    // for fvm::laplacian, lower = upper
    double upper_value = face_gamma * mag_sf[index] * delta_coeffs[index];
    double lower_value = upper_value;

    lower_value = lower_value * sign;
    upper_value = upper_value * sign;

    lower[index] += lower_value;
    upper[index] += upper_value;

    atomicAdd(&(diag[owner]), -lower_value);
    atomicAdd(&(diag[neighbor]), -upper_value);
}

__global__ void fvm_laplacian_scalar_boundary(int num, int offset,
        const double *boundary_mag_sf, const double *boundary_gamma,
        const double *gradient_internal_coeffs, const double *gradient_boundary_coeffs,
        double *internal_coeffs, double *boundary_coeffs, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;

    int start_index = offset + index;
    double boundary_value = boundary_gamma[start_index] * boundary_mag_sf[start_index];
    internal_coeffs[start_index] += boundary_value * gradient_internal_coeffs[start_index] * sign;
    boundary_coeffs[start_index] -= boundary_value * gradient_boundary_coeffs[start_index] * sign;
}

__global__ void fvm_laplacian_surface_scalar_boundary(int num_boundary_surfaces,
        const double *boundary_mag_sf, const double *boundary_gamma,
        const double *gradient_internal_coeffs, const double *gradient_boundary_coeffs,
        double *internal_coeffs, double *boundary_coeffs, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_boundary_surfaces)
        return;

    double boundary_value = boundary_gamma[index] * boundary_mag_sf[index];
    internal_coeffs[index] += boundary_value * gradient_internal_coeffs[index] * sign;
    boundary_coeffs[index] -= boundary_value * gradient_boundary_coeffs[index] * sign;
}

__global__ void fvm_laplacian_vector_boundary(int num_boundary_surfaces, int num, int offset,
        const double *boundary_mag_sf, const double *boundary_gamma,
        const double *gradient_internal_coeffs, const double *gradient_boundary_coeffs,
        double *internal_coeffs, double *boundary_coeffs, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;

    int start_index = offset + index;
    double boundary_value = boundary_gamma[start_index] * boundary_mag_sf[start_index];
    internal_coeffs[num_boundary_surfaces * 0 + start_index] += boundary_value * gradient_internal_coeffs[num_boundary_surfaces * 0 + start_index] * sign;
    internal_coeffs[num_boundary_surfaces * 1 + start_index] += boundary_value * gradient_internal_coeffs[num_boundary_surfaces * 1 + start_index] * sign;
    internal_coeffs[num_boundary_surfaces * 2 + start_index] += boundary_value * gradient_internal_coeffs[num_boundary_surfaces * 2 + start_index] * sign;
    boundary_coeffs[num_boundary_surfaces * 0 + start_index] -= boundary_value * gradient_boundary_coeffs[num_boundary_surfaces * 0 + start_index] * sign;
    boundary_coeffs[num_boundary_surfaces * 1 + start_index] -= boundary_value * gradient_boundary_coeffs[num_boundary_surfaces * 1 + start_index] * sign;
    boundary_coeffs[num_boundary_surfaces * 2 + start_index] -= boundary_value * gradient_boundary_coeffs[num_boundary_surfaces * 2 + start_index] * sign;
}

__global__ void fvc_ddt_vol_scalar_vol_scalar_kernel(int num_cells, double rDeltaT,
        const double *rho, const double *rho_old, const double *vf, const double *vf_old, const double *volume, 
        double *output, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_cells)
        return;
    /*
    // workaround way1 (use printf):
    double val_new = rho[index] * vf[index];
    double val_old = rho_old[index] * vf_old[index];
    // TODO: skip moving
    // TODO: wyr
    // for the case of rho = rho_old and vf = vf_old, the floating-point numerical problem will be exposed.
    // it expect zero as output, but the gpu result get a sub-normal minimal value for (val_new - val_old),
    // which smaller than 1e-16, and then enlarged by rDeltaT (1e6)
    // then the comparison of cpu result and gpu result will failed with relative error: inf,
    // e.g.:
    // cpu data: 0.0000000000000000, gpu data: 0.0000000000298050, relative error: inf
    // if I add the print line for intermediate variables of val_new and val_old, the problem disappears.
    // It seems that print line will change the compiler behavior, maybe avoiding the fma optimization of compiler.
    if (index == -1) printf("index = 0, val_new: %.40lf, val_old: %.40lf\n", val_new, val_old);
    output[index] += rDeltaT * (val_new - val_old);
    */
    /*
    // workaround way2 (use volatile):
    // volatile will change the compiler behavior, maybe avoiding the fma optimization of compiler.
    volatile double val_new = rho[index] * vf[index];
    volatile double val_old = rho_old[index] * vf_old[index];
    output[index] += rDeltaT * (val_new - val_old);
    */
    // workaround way3 (use nvcc option -fmad=false)
    output[index] += rDeltaT * (rho[index] * vf[index] - rho_old[index] * vf_old[index]) * volume[index] * sign;
}

__global__ void fvc_grad_vector_internal(int num_cells, int num_surfaces, 
        const int *lower_index, const int *upper_index, const double *face_vector,
        const double *weight, const double *field_vector, 
        double *output)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_surfaces)
        return;
    
    double w = weight[index];
    double Sfx = face_vector[num_surfaces * 0 + index];
    double Sfy = face_vector[num_surfaces * 1 + index];
    double Sfz = face_vector[num_surfaces * 2 + index];

    int owner = lower_index[index];
    int neighbor = upper_index[index];

    double ssfx = (w * (field_vector[num_cells * 0 + owner] - field_vector[num_cells * 0 + neighbor]) + field_vector[num_cells * 0 + neighbor]);
    double ssfy = (w * (field_vector[num_cells * 1 + owner] - field_vector[num_cells * 1 + neighbor]) + field_vector[num_cells * 1 + neighbor]);
    double ssfz = (w * (field_vector[num_cells * 2 + owner] - field_vector[num_cells * 2 + neighbor]) + field_vector[num_cells * 2 + neighbor]);    

    double grad_xx = Sfx * ssfx;
    double grad_xy = Sfx * ssfy;
    double grad_xz = Sfx * ssfz;
    double grad_yx = Sfy * ssfx;
    double grad_yy = Sfy * ssfy;
    double grad_yz = Sfy * ssfz;
    double grad_zx = Sfz * ssfx;
    double grad_zy = Sfz * ssfy;
    double grad_zz = Sfz * ssfz;

    // // owner
    // atomicAdd(&(output[num_cells * 0 + owner]), grad_xx);
    // atomicAdd(&(output[num_cells * 1 + owner]), grad_xy);
    // atomicAdd(&(output[num_cells * 2 + owner]), grad_xz);
    // atomicAdd(&(output[num_cells * 3 + owner]), grad_yx);
    // atomicAdd(&(output[num_cells * 4 + owner]), grad_yy);
    // atomicAdd(&(output[num_cells * 5 + owner]), grad_yz);
    // atomicAdd(&(output[num_cells * 6 + owner]), grad_zx);
    // atomicAdd(&(output[num_cells * 7 + owner]), grad_zy);
    // atomicAdd(&(output[num_cells * 8 + owner]), grad_zz);

    // // neighbour
    // atomicAdd(&(output[num_cells * 0 + neighbor]), -grad_xx);
    // atomicAdd(&(output[num_cells * 1 + neighbor]), -grad_xy);
    // atomicAdd(&(output[num_cells * 2 + neighbor]), -grad_xz);
    // atomicAdd(&(output[num_cells * 3 + neighbor]), -grad_yx);
    // atomicAdd(&(output[num_cells * 4 + neighbor]), -grad_yy);
    // atomicAdd(&(output[num_cells * 5 + neighbor]), -grad_yz);
    // atomicAdd(&(output[num_cells * 6 + neighbor]), -grad_zx);
    // atomicAdd(&(output[num_cells * 7 + neighbor]), -grad_zy);
    // atomicAdd(&(output[num_cells * 8 + neighbor]), -grad_zz);

    atomicAdd(&(output[num_cells * 0 + owner]), grad_xx);
    atomicAdd(&(output[num_cells * 0 + neighbor]), -grad_xx);
    atomicAdd(&(output[num_cells * 1 + owner]), grad_xy);
    atomicAdd(&(output[num_cells * 1 + neighbor]), -grad_xy);
    atomicAdd(&(output[num_cells * 2 + owner]), grad_xz);
    atomicAdd(&(output[num_cells * 2 + neighbor]), -grad_xz);
    atomicAdd(&(output[num_cells * 3 + owner]), grad_yx);
    atomicAdd(&(output[num_cells * 3 + neighbor]), -grad_yx);
    atomicAdd(&(output[num_cells * 4 + owner]), grad_yy);
    atomicAdd(&(output[num_cells * 4 + neighbor]), -grad_yy);
    atomicAdd(&(output[num_cells * 5 + owner]), grad_yz);
    atomicAdd(&(output[num_cells * 5 + neighbor]), -grad_yz);
    atomicAdd(&(output[num_cells * 6 + owner]), grad_zx);
    atomicAdd(&(output[num_cells * 6 + neighbor]), -grad_zx);
    atomicAdd(&(output[num_cells * 7 + owner]), grad_zy);
    atomicAdd(&(output[num_cells * 7 + neighbor]), -grad_zy);
    atomicAdd(&(output[num_cells * 8 + owner]), grad_zz);
    atomicAdd(&(output[num_cells * 8 + neighbor]), -grad_zz);
}

// update boundary of interpolation field
// calculate the grad field
// TODO: this function is implemented for uncoupled boundary conditions
//       so it should use the more specific func name
__global__ void fvc_grad_vector_boundary(int num_boundary_surfaces, int num_cells, int num, 
        int offset, const int *face2Cells, const double *boundary_face_vector, 
        const double *boundary_field_vector, double *output)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;

    int start_index = offset + index;

    double bouSfx = boundary_face_vector[num_boundary_surfaces * 0 + start_index];
    double bouSfy = boundary_face_vector[num_boundary_surfaces * 1 + start_index];
    double bouSfz = boundary_face_vector[num_boundary_surfaces * 2 + start_index];

    double boussfx = boundary_field_vector[num_boundary_surfaces * 0 + start_index];
    double boussfy = boundary_field_vector[num_boundary_surfaces * 1 + start_index];
    double boussfz = boundary_field_vector[num_boundary_surfaces * 2 + start_index];

    int cellIndex = face2Cells[start_index];

    double grad_xx = bouSfx * boussfx;
    double grad_xy = bouSfx * boussfy;
    double grad_xz = bouSfx * boussfz;
    double grad_yx = bouSfy * boussfx;
    double grad_yy = bouSfy * boussfy;
    double grad_yz = bouSfy * boussfz;
    double grad_zx = bouSfz * boussfx;
    double grad_zy = bouSfz * boussfy;
    double grad_zz = bouSfz * boussfz;

    atomicAdd(&(output[num_cells * 0 + cellIndex]), grad_xx);
    atomicAdd(&(output[num_cells * 1 + cellIndex]), grad_xy);
    atomicAdd(&(output[num_cells * 2 + cellIndex]), grad_xz);
    atomicAdd(&(output[num_cells * 3 + cellIndex]), grad_yx);
    atomicAdd(&(output[num_cells * 4 + cellIndex]), grad_yy);
    atomicAdd(&(output[num_cells * 5 + cellIndex]), grad_yz);
    atomicAdd(&(output[num_cells * 6 + cellIndex]), grad_zx);
    atomicAdd(&(output[num_cells * 7 + cellIndex]), grad_zy);
    atomicAdd(&(output[num_cells * 8 + cellIndex]), grad_zz);
}

__global__ void fvc_grad_scalar_internal(int num_cells, int num_surfaces,
        const int *lower_index, const int *upper_index, const double *face_vector, 
        const double *weight, const double *vf, double *output, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_surfaces)
        return;
    
    double w = weight[index];
    double Sfx = face_vector[num_surfaces * 0 + index];
    double Sfy = face_vector[num_surfaces * 1 + index];
    double Sfz = face_vector[num_surfaces * 2 + index];

    int owner = lower_index[index];
    int neighbor = upper_index[index];

    double ssf = (w * (vf[owner] - vf[neighbor]) + vf[neighbor]);

    double grad_x = Sfx * ssf * sign;
    double grad_y = Sfy * ssf * sign;
    double grad_z = Sfz * ssf * sign;

    // owner
    atomicAdd(&(output[num_cells * 0 + owner]), grad_x);
    atomicAdd(&(output[num_cells * 1 + owner]), grad_y);
    atomicAdd(&(output[num_cells * 2 + owner]), grad_z);

    // neighbour
    atomicAdd(&(output[num_cells * 0 + neighbor]), -grad_x);
    atomicAdd(&(output[num_cells * 1 + neighbor]), -grad_y);
    atomicAdd(&(output[num_cells * 2 + neighbor]), -grad_z);
}

__global__ void fvc_grad_scalar_boundary(int num_boundary_surfaces, int num_cells, int num, int offset, const int *face2Cells,
        const double *boundary_face_vector, const double *boundary_vf, double *output, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;

    int start_index = offset + index;

    double bouvf = boundary_vf[start_index];
    double bouSfx = boundary_face_vector[num_boundary_surfaces * 0 + start_index];
    double bouSfy = boundary_face_vector[num_boundary_surfaces * 1 + start_index];
    double bouSfz = boundary_face_vector[num_boundary_surfaces * 2 + start_index];

    int cellIndex = face2Cells[start_index];

    double grad_x = bouSfx * bouvf;
    double grad_y = bouSfy * bouvf;
    double grad_z = bouSfz * bouvf;

    atomicAdd(&(output[num_cells * 0 + cellIndex]), grad_x * sign);
    atomicAdd(&(output[num_cells * 1 + cellIndex]), grad_y * sign);
    atomicAdd(&(output[num_cells * 2 + cellIndex]), grad_z * sign);

    // if (cellIndex == 5)
    // {
    //     printf("Sfx = %.10e, ssf = %.10e\n", bouSfx, bouvf);
    //     printf("gradx = %.10e, output = %.10e\n\n", grad_x, output[5]);
    // }
}

__global__ void divide_cell_volume_tsr(int num_cells, const double* volume, double *output)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_cells)
        return;
    
    double vol = volume[index];
    output[num_cells * 0 + index] = output[num_cells * 0 + index] / vol;
    output[num_cells * 1 + index] = output[num_cells * 1 + index] / vol;
    output[num_cells * 2 + index] = output[num_cells * 2 + index] / vol;
    output[num_cells * 3 + index] = output[num_cells * 3 + index] / vol;
    output[num_cells * 4 + index] = output[num_cells * 4 + index] / vol;
    output[num_cells * 5 + index] = output[num_cells * 5 + index] / vol;
    output[num_cells * 6 + index] = output[num_cells * 6 + index] / vol;
    output[num_cells * 7 + index] = output[num_cells * 7 + index] / vol;
    output[num_cells * 8 + index] = output[num_cells * 8 + index] / vol;
}

__global__ void divide_cell_volume_vec(int num_cells, const double* volume, double *output)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_cells)
        return;
    
    double vol = volume[index];

    output[num_cells * 0 + index] = output[num_cells * 0 + index] / vol;
    output[num_cells * 1 + index] = output[num_cells * 1 + index] / vol;
    output[num_cells * 2 + index] = output[num_cells * 2 + index] / vol;
}

__global__ void divide_cell_volume_scalar(int num_cells, const double* volume, double *output)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_cells)
        return;
    
    double vol = volume[index];

    output[index] = output[index] / vol;
}

__global__ void fvc_grad_vector_correctBC_zeroGradient(int num_cells, int num_boundary_surfaces, 
        int num, int offset, const int *face2Cells, 
        const double *internal_grad, const double *boundary_vf, const double *boundary_sf,
        const double *boundary_mag_sf, double *boundary_grad)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;

    int start_index = offset + index;

    int cellIndex = face2Cells[start_index];

    double grad_xx = internal_grad[num_cells * 0 + cellIndex];
    double grad_xy = internal_grad[num_cells * 1 + cellIndex];
    double grad_xz = internal_grad[num_cells * 2 + cellIndex];
    double grad_yx = internal_grad[num_cells * 3 + cellIndex];
    double grad_yy = internal_grad[num_cells * 4 + cellIndex];
    double grad_yz = internal_grad[num_cells * 5 + cellIndex];
    double grad_zx = internal_grad[num_cells * 6 + cellIndex];
    double grad_zy = internal_grad[num_cells * 7 + cellIndex];
    double grad_zz = internal_grad[num_cells * 8 + cellIndex];

    double n_x = boundary_sf[num_boundary_surfaces * 0 + start_index] / boundary_mag_sf[start_index];
    double n_y = boundary_sf[num_boundary_surfaces * 1 + start_index] / boundary_mag_sf[start_index];
    double n_z = boundary_sf[num_boundary_surfaces * 2 + start_index] / boundary_mag_sf[start_index];
    
    double grad_correction_x = - (n_x * grad_xx + n_y * grad_yx + n_z * grad_zx); // sn_grad_x = 0
    double grad_correction_y = - (n_x * grad_xy + n_y * grad_yy + n_z * grad_zy);
    double grad_correction_z = - (n_x * grad_xz + n_y * grad_yz + n_z * grad_zz);

    boundary_grad[num_boundary_surfaces * 0 + start_index] = grad_xx + n_x * grad_correction_x;
    boundary_grad[num_boundary_surfaces * 1 + start_index] = grad_xy + n_x * grad_correction_y;
    boundary_grad[num_boundary_surfaces * 2 + start_index] = grad_xz + n_x * grad_correction_z;
    boundary_grad[num_boundary_surfaces * 3 + start_index] = grad_yx + n_y * grad_correction_x;
    boundary_grad[num_boundary_surfaces * 4 + start_index] = grad_yy + n_y * grad_correction_y;
    boundary_grad[num_boundary_surfaces * 5 + start_index] = grad_yz + n_y * grad_correction_z;
    boundary_grad[num_boundary_surfaces * 6 + start_index] = grad_zx + n_z * grad_correction_x;
    boundary_grad[num_boundary_surfaces * 7 + start_index] = grad_zy + n_z * grad_correction_y;
    boundary_grad[num_boundary_surfaces * 8 + start_index] = grad_zz + n_z * grad_correction_z;
}

__global__ void fvc_grad_vector_correctBC_fixedValue(int num_cells, int num_boundary_surfaces,
        int num, int offset, const int *face2Cells,
        const double *internal_grad, const double *vf, const double *boundary_sf,
        const double *boundary_mag_sf, double *boundary_grad,
        const double *boundary_deltaCoeffs, const double *boundary_vf)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;

    int start_index = offset + index;

    int cellIndex = face2Cells[start_index];

    double grad_xx = internal_grad[num_cells * 0 + cellIndex];
    double grad_xy = internal_grad[num_cells * 1 + cellIndex];
    double grad_xz = internal_grad[num_cells * 2 + cellIndex];
    double grad_yx = internal_grad[num_cells * 3 + cellIndex];
    double grad_yy = internal_grad[num_cells * 4 + cellIndex];
    double grad_yz = internal_grad[num_cells * 5 + cellIndex];
    double grad_zx = internal_grad[num_cells * 6 + cellIndex];
    double grad_zy = internal_grad[num_cells * 7 + cellIndex];
    double grad_zz = internal_grad[num_cells * 8 + cellIndex];

    double n_x = boundary_sf[num_boundary_surfaces * 0 + start_index] / boundary_mag_sf[start_index];
    double n_y = boundary_sf[num_boundary_surfaces * 1 + start_index] / boundary_mag_sf[start_index];
    double n_z = boundary_sf[num_boundary_surfaces * 2 + start_index] / boundary_mag_sf[start_index];
    
    // sn_grad: solving according to fixedValue BC
    double sn_grad_x = boundary_deltaCoeffs[start_index] * (boundary_vf[num_boundary_surfaces * 0 + start_index] - vf[num_cells * 0 + cellIndex]);
    double sn_grad_y = boundary_deltaCoeffs[start_index] * (boundary_vf[num_boundary_surfaces * 1 + start_index] - vf[num_cells * 1 + cellIndex]);
    double sn_grad_z = boundary_deltaCoeffs[start_index] * (boundary_vf[num_boundary_surfaces * 2 + start_index] - vf[num_cells * 2 + cellIndex]);

    double grad_correction_x = sn_grad_x - (n_x * grad_xx + n_y * grad_yx + n_z * grad_zx); // sn_grad_x = 0
    double grad_correction_y = sn_grad_y - (n_x * grad_xy + n_y * grad_yy + n_z * grad_zy);
    double grad_correction_z = sn_grad_z - (n_x * grad_xz + n_y * grad_yz + n_z * grad_zz);

    boundary_grad[num_boundary_surfaces * 0 + start_index] = grad_xx + n_x * grad_correction_x;
    boundary_grad[num_boundary_surfaces * 1 + start_index] = grad_xy + n_x * grad_correction_y;
    boundary_grad[num_boundary_surfaces * 2 + start_index] = grad_xz + n_x * grad_correction_z;
    boundary_grad[num_boundary_surfaces * 3 + start_index] = grad_yx + n_y * grad_correction_x;
    boundary_grad[num_boundary_surfaces * 4 + start_index] = grad_yy + n_y * grad_correction_y;
    boundary_grad[num_boundary_surfaces * 5 + start_index] = grad_yz + n_y * grad_correction_z;
    boundary_grad[num_boundary_surfaces * 6 + start_index] = grad_zx + n_z * grad_correction_x;
    boundary_grad[num_boundary_surfaces * 7 + start_index] = grad_zy + n_z * grad_correction_y;
    boundary_grad[num_boundary_surfaces * 8 + start_index] = grad_zz + n_z * grad_correction_z;
}

__global__ void fvc_grad_cell_scalar_correctBC_zeroGradient(int num_cells, int num_boundary_surfaces,
        int num, int offset, const int *face2Cells,
        const double *internal_grad, const double *boundary_sf,
        const double *boundary_mag_sf, double *boundary_grad)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;

    int start_index = offset + index;
    int cellIndex = face2Cells[start_index];

    double grad_x = internal_grad[num_cells * 0 + cellIndex];
    double grad_y = internal_grad[num_cells * 1 + cellIndex];
    double grad_z = internal_grad[num_cells * 2 + cellIndex];

    double n_x = boundary_sf[num_boundary_surfaces * 0 + start_index] / boundary_mag_sf[start_index];
    double n_y = boundary_sf[num_boundary_surfaces * 1 + start_index] / boundary_mag_sf[start_index];
    double n_z = boundary_sf[num_boundary_surfaces * 2 + start_index] / boundary_mag_sf[start_index];

    double grad_correction = -(n_x * grad_x + n_y * grad_y + n_z * grad_z); // sn_grad_x = 0

    boundary_grad[num_boundary_surfaces * 0 + start_index] = grad_x + n_x * grad_correction;
    boundary_grad[num_boundary_surfaces * 1 + start_index] = grad_y + n_y * grad_correction;
    boundary_grad[num_boundary_surfaces * 2 + start_index] = grad_z + n_z * grad_correction;
}

__global__ void fvc_grad_cell_scalar_correctBC_fixedValue(int num_cells, int num_boundary_surfaces,
        int num, int offset, const int *face2Cells,
        const double *internal_grad, const double *vf, const double *boundary_sf,
        const double *boundary_mag_sf, double *boundary_grad,
        const double *boundary_deltaCoeffs, const double *boundary_vf)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;

    int start_index = offset + index;
    int cellIndex = face2Cells[start_index];

    double grad_x = internal_grad[num_cells * 0 + cellIndex];
    double grad_y = internal_grad[num_cells * 1 + cellIndex];
    double grad_z = internal_grad[num_cells * 2 + cellIndex];

    double n_x = boundary_sf[num_boundary_surfaces * 0 + start_index] / boundary_mag_sf[start_index];
    double n_y = boundary_sf[num_boundary_surfaces * 1 + start_index] / boundary_mag_sf[start_index];
    double n_z = boundary_sf[num_boundary_surfaces * 2 + start_index] / boundary_mag_sf[start_index];

    // sn_grad: solving according to fixedValue BC
    double sn_grad = boundary_deltaCoeffs[start_index] * (boundary_vf[start_index] - vf[cellIndex]);
    double grad_correction = sn_grad - (n_x * grad_x + n_y * grad_y + n_z * grad_z);

    boundary_grad[num_boundary_surfaces * 0 + start_index] = grad_x + n_x * grad_correction;
    boundary_grad[num_boundary_surfaces * 1 + start_index] = grad_y + n_y * grad_correction;
    boundary_grad[num_boundary_surfaces * 2 + start_index] = grad_z + n_z * grad_correction;
}

__global__ void fvc_div_surface_scalar_internal(int num_surfaces, 
        const int *lower_index, const int *upper_index, const double *ssf,
        double *output, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_surfaces)
        return;

    int owner = lower_index[index];
    int neighbor = upper_index[index];

    double issf = ssf[index];

    // owner
    atomicAdd(&(output[owner]), issf * sign);

    // neighbor
    atomicAdd(&(output[neighbor]), -issf * sign);
}

__global__ void fvc_div_surface_scalar_vol_scalar_internal(int num_surfaces, 
        const int *lower_index, const int *upper_index, const double *weight,
        const double *faceFlux, const double *vf, double *output, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_surfaces)
        return;

    int owner = lower_index[index];
    int neighbor = upper_index[index];

    double w = weight[index];
    double flux = faceFlux[index] * (w * (vf[owner] - vf[neighbor]) + vf[neighbor]);

    // owner
    atomicAdd(&(output[owner]), flux * sign);

    // neighbor
    atomicAdd(&(output[neighbor]), -flux * sign);
}

__global__ void fvc_div_surface_scalar_boundary(int num_boundary_face, const int *face2Cells,
        const double *boundary_ssf, double *output, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_boundary_face)
        return;
    
    int cellIndex = face2Cells[index];

    atomicAdd(&(output[cellIndex]), boundary_ssf[index] * sign);
}

__global__ void fvc_div_surface_scalar_vol_scalar_boundary(int num, int offset, const int *face2Cells,
        const double *boundary_vf, const double *boundary_ssf, double *output, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;
    
    int start_index = offset + index;
    
    int cellIndex = face2Cells[start_index];

    atomicAdd(&(output[cellIndex]), boundary_ssf[start_index] * boundary_vf[start_index] * sign);
}

__global__ void fvc_div_cell_vector_internal(int num_cells, int num_surfaces, 
        const int *lower_index, const int *upper_index,
        const double *field_vector, const double *weight, const double *face_vector,
        double *output, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_surfaces)
        return;

    double w = weight[index];
    double Sfx = face_vector[num_surfaces * 0 + index];
    double Sfy = face_vector[num_surfaces * 1 + index];
    double Sfz = face_vector[num_surfaces * 2 + index];

    int owner = lower_index[index];
    int neighbor = upper_index[index];

    double ssfx = (w * (field_vector[num_cells * 0 + owner] - field_vector[num_cells * 0 + neighbor]) + field_vector[num_cells * 0 + neighbor]);
    double ssfy = (w * (field_vector[num_cells * 1 + owner] - field_vector[num_cells * 1 + neighbor]) + field_vector[num_cells * 1 + neighbor]);
    double ssfz = (w * (field_vector[num_cells * 2 + owner] - field_vector[num_cells * 2 + neighbor]) + field_vector[num_cells * 2 + neighbor]);

    double div = Sfx * ssfx + Sfy * ssfy + Sfz * ssfz;

    // owner
    atomicAdd(&(output[owner]), div * sign);

    // neighbour
    atomicAdd(&(output[neighbor]), -div * sign);
}

__global__ void fvc_div_cell_vector_boundary(int num_boundary_surfaces, int num, int offset, const int *face2Cells,
        const double *boundary_face_vector, const double *boundary_field_vector, double *output, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;

    int start_index = offset + index;

    double bouSfx = boundary_face_vector[num_boundary_surfaces * 0 + start_index];
    double bouSfy = boundary_face_vector[num_boundary_surfaces * 1 + start_index];
    double bouSfz = boundary_face_vector[num_boundary_surfaces * 2 + start_index];

    double boussfx = boundary_field_vector[num_boundary_surfaces * 0 + start_index];
    double boussfy = boundary_field_vector[num_boundary_surfaces * 1 + start_index];
    double boussfz = boundary_field_vector[num_boundary_surfaces * 2 + start_index];

    int cellIndex = face2Cells[start_index];

    double bouDiv = bouSfx * boussfx + bouSfy * boussfy + bouSfz * boussfz;

    atomicAdd(&(output[cellIndex]), bouDiv * sign);
}

__global__ void fvc_div_cell_tensor_internal(int num_cells, int num_surfaces,
        const int *lower_index, const int *upper_index,
        const double *vf, const double *weight, const double *face_vector,
        double *output, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_surfaces)
        return;

    double w = weight[index];
    double Sfx = face_vector[num_surfaces * 0 + index];
    double Sfy = face_vector[num_surfaces * 1 + index];
    double Sfz = face_vector[num_surfaces * 2 + index];
    int owner = lower_index[index];
    int neighbor = upper_index[index];

    double ssf_xx = (w * (vf[num_cells * 0 + owner] - vf[num_cells * 0 + neighbor]) + vf[num_cells * 0 + neighbor]);
    double ssf_xy = (w * (vf[num_cells * 1 + owner] - vf[num_cells * 1 + neighbor]) + vf[num_cells * 1 + neighbor]);
    double ssf_xz = (w * (vf[num_cells * 2 + owner] - vf[num_cells * 2 + neighbor]) + vf[num_cells * 2 + neighbor]);
    double ssf_yx = (w * (vf[num_cells * 3 + owner] - vf[num_cells * 3 + neighbor]) + vf[num_cells * 3 + neighbor]);
    double ssf_yy = (w * (vf[num_cells * 4 + owner] - vf[num_cells * 4 + neighbor]) + vf[num_cells * 4 + neighbor]);
    double ssf_yz = (w * (vf[num_cells * 5 + owner] - vf[num_cells * 5 + neighbor]) + vf[num_cells * 5 + neighbor]);
    double ssf_zx = (w * (vf[num_cells * 6 + owner] - vf[num_cells * 6 + neighbor]) + vf[num_cells * 6 + neighbor]);
    double ssf_zy = (w * (vf[num_cells * 7 + owner] - vf[num_cells * 7 + neighbor]) + vf[num_cells * 7 + neighbor]);
    double ssf_zz = (w * (vf[num_cells * 8 + owner] - vf[num_cells * 8 + neighbor]) + vf[num_cells * 8 + neighbor]);
    double div_x = (Sfx * ssf_xx + Sfy * ssf_yx + Sfz * ssf_zx) * sign;
    double div_y = (Sfx * ssf_xy + Sfy * ssf_yy + Sfz * ssf_zy) * sign;
    double div_z = (Sfx * ssf_xz + Sfy * ssf_yz + Sfz * ssf_zz) * sign;
    
    // owner
    atomicAdd(&(output[num_cells * 0 + owner]), div_x);
    atomicAdd(&(output[num_cells * 1 + owner]), div_y);
    atomicAdd(&(output[num_cells * 2 + owner]), div_z);

    // neighbour
    atomicAdd(&(output[num_cells * 0 + neighbor]), -div_x);
    atomicAdd(&(output[num_cells * 1 + neighbor]), -div_y);
    atomicAdd(&(output[num_cells * 2 + neighbor]), -div_z);
}

__global__ void fvc_div_cell_tensor_boundary(int num_cells, int num_boundary_faces, int num, int offset, const int *face2Cells,
        const double *boundary_face_vector, const double *boundary_vf, double *output, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;

    int start_index = offset + index;

    double bouSfx = boundary_face_vector[num_boundary_faces * 0 + start_index];
    double bouSfy = boundary_face_vector[num_boundary_faces * 1 + start_index];
    double bouSfz = boundary_face_vector[num_boundary_faces * 2 + start_index];

    double boussf_xx = boundary_vf[num_boundary_faces * 0 + start_index];
    double boussf_xy = boundary_vf[num_boundary_faces * 1 + start_index];
    double boussf_xz = boundary_vf[num_boundary_faces * 2 + start_index];
    double boussf_yx = boundary_vf[num_boundary_faces * 3 + start_index];
    double boussf_yy = boundary_vf[num_boundary_faces * 4 + start_index];
    double boussf_yz = boundary_vf[num_boundary_faces * 5 + start_index];
    double boussf_zx = boundary_vf[num_boundary_faces * 6 + start_index];
    double boussf_zy = boundary_vf[num_boundary_faces * 7 + start_index];
    double boussf_zz = boundary_vf[num_boundary_faces * 8 + start_index];
    int cellIndex = face2Cells[start_index];

    double bouDiv_x = (bouSfx * boussf_xx + bouSfy * boussf_yx + bouSfz * boussf_zx) * sign;
    double bouDiv_y = (bouSfx * boussf_xy + bouSfy * boussf_yy + bouSfz * boussf_zy) * sign;
    double bouDiv_z = (bouSfx * boussf_xz + bouSfy * boussf_yz + bouSfz * boussf_zz) * sign;

    atomicAdd(&(output[num_cells * 0 + cellIndex]), bouDiv_x);
    atomicAdd(&(output[num_cells * 1 + cellIndex]), bouDiv_y);
    atomicAdd(&(output[num_cells * 2 + cellIndex]), bouDiv_z);

    // if (cellIndex == 0)
    // {
    //     // printf("gpu output[0] = %.5e, %.5e, %.5e\n", output[0], output[1], output[2]);
    //     // printf("gpu output[0] += %.5e, %.5e, %.5e\n", bouDiv_x, bouDiv_y, bouDiv_z);
    //     printf("gpu bouvf[0] = (%.5e, %.5e, %.5e, %.5e, %.5e, %.5e, %.5e, %.5e, %.5e)\n", 
    //             boussf_xx, boussf_xy, boussf_xz, boussf_yx, boussf_yy, boussf_yz, boussf_zx, boussf_zy, boussf_zz);
    //     printf("gpu bouSf[0] = (%.5e, %.5e, %.5e)\n", bouSfx, bouSfy, bouSfz);
    //     printf("gpu boufinal[0] = (%.5e, %.5e, %.5e)\n", bouDiv_x, bouDiv_y, bouDiv_z);
    //     printf("bouIndex = %d\n\n", start_index);
    // }

    // if (index == 0)
    // {
    //     printf("bou_grad_U = (%.5e, %.5e, %.5e, %.5e, %.5e, %.5e, %.5e, %.5e, %.5e)", vf2[0], vf2[1], vf2[2],
    //             vf2[3], vf2[4], vf2[5], vf2[6], vf2[7], vf2[8]);
    // }
}

__global__ void fvc_laplacian_scalar_internal(int num_surfaces,
        const int *lower_index, const int *upper_index,
        const double *mag_sf, const double *delta_coeffs,
        const double *gamma, const double *vf, double *output, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_surfaces)
        return;

    int owner = lower_index[index];
    int neighbor = upper_index[index];

    double sngrad = delta_coeffs[index] * (vf[neighbor] - vf[owner]);
    double issf = gamma[index] * sngrad * mag_sf[index] * sign;

    // owner
    atomicAdd(&(output[owner]), issf);

    // neighbor
    atomicAdd(&(output[neighbor]), -issf);
}

__global__ void fvc_laplacian_scalar_boundary_fixedValue(int num, int offset, const int *face2Cells,
        const double *boundary_mag_sf, const double *boundary_delta_coeffs,
        const double *boundary_gamma, const double *vf, const double *boundary_vf, double *output, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;

    int start_index = offset + index;
    int cellIndex = face2Cells[index];

    // sn_grad: solving according to fixedValue BC
    double boundary_sngrad = boundary_delta_coeffs[start_index] * (boundary_vf[start_index] - vf[cellIndex]);
    double boundary_ssf = boundary_gamma[start_index] * boundary_sngrad * boundary_mag_sf[start_index] * sign;

    atomicAdd(&(output[cellIndex]), boundary_ssf);
}

__global__ void fvc_flux_internal_kernel(int num_cells, int num_surfaces, 
        const int *lower_index, const int *upper_index,
        const double *field_vector, const double *weight, const double *face_vector,
        double *output, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_surfaces)
        return;

    double w = weight[index];
    double Sfx = face_vector[num_surfaces * 0 + index];
    double Sfy = face_vector[num_surfaces * 1 + index];
    double Sfz = face_vector[num_surfaces * 2 + index];

    int owner = lower_index[index];
    int neighbor = upper_index[index];

    double ssfx = (w * (field_vector[num_cells * 0 + owner] - field_vector[num_cells * 0 + neighbor]) + field_vector[num_cells * 0 + neighbor]);
    double ssfy = (w * (field_vector[num_cells * 1 + owner] - field_vector[num_cells * 1 + neighbor]) + field_vector[num_cells * 1 + neighbor]);
    double ssfz = (w * (field_vector[num_cells * 2 + owner] - field_vector[num_cells * 2 + neighbor]) + field_vector[num_cells * 2 + neighbor]);

    output[index] = Sfx * ssfx + Sfy * ssfy + Sfz * ssfz;
}

__global__ void fvc_interpolate_internal_kernel(int num_surfaces, const int *lower_index, const int *upper_index,
        const double *vf, const double *weight, double *output, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_surfaces)
        return;
    
    double w = weight[index];

    int owner = lower_index[index];
    int neighbor = upper_index[index];

    output[index] = (w * (vf[owner] - vf[neighbor]) + vf[neighbor]);
}

__global__ void fvc_flux_boundary_kernel(int num_boundary_surfaces, int num, int offset, const int *face2Cells,
        const double *boundary_face_vector, const double *boundary_field_vector, double *output, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;
    
    int start_index = offset + index;

    double bouSfx = boundary_face_vector[num_boundary_surfaces * 0 + start_index];
    double bouSfy = boundary_face_vector[num_boundary_surfaces * 1 + start_index];
    double bouSfz = boundary_face_vector[num_boundary_surfaces * 2 + start_index];

    double boussfx = boundary_field_vector[num_boundary_surfaces * 0 + start_index];
    double boussfy = boundary_field_vector[num_boundary_surfaces * 1 + start_index];
    double boussfz = boundary_field_vector[num_boundary_surfaces * 2 + start_index];

    output[start_index] = bouSfx * boussfx + bouSfy * boussfy + bouSfz * boussfz;
}

__global__ void fvc_interpolate_boundary_kernel_upCouple(int num, int offset,
        const double *boundary_vf, double *output, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;
    
    int start_index = offset + index;
    output[start_index] = boundary_vf[start_index];
}

__global__ void fvc_ddt_scalar_kernel(int num_cells, const double *vf, const double *vf_old,
        const double rDeltaT, const double *volume, double *source, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_cells)
        return;
    
    source[index] += (vf[index] - vf_old[index]) * rDeltaT * volume[index] * sign;
}

__global__ void fvc_ddt_scalar_field_kernel(int num_cells, const double *vf, const double *vf_old,
        const double rDeltaT, const double *volume, double *source, double sign)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_cells)
        return;
    
    source[index] = (vf[index] - vf_old[index]) * rDeltaT * sign;
}

__global__ void addBoundaryDiagSrc_scalar(int num_boundary_surfaces, const int *face2Cells,
        const double *internal_coeffs, const double *boundary_coeffs, double *diag, double *source)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_boundary_surfaces)
        return;
    
    int cellIndex = face2Cells[index];

    double internalCoeff = internal_coeffs[index];
    double boundaryCoeff = boundary_coeffs[index];

    atomicAdd(&diag[cellIndex], internalCoeff);
    atomicAdd(&source[cellIndex], boundaryCoeff);
}

__global__ void addBoundaryDiagSrc(int num_cells, int num_surfaces, int num_boundary_surfaces, const int *face2Cells, 
        const double *internal_coeffs, const double *boundary_coeffs, const int *diagCSRIndex, 
        double *A_csr, double *b)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_boundary_surfaces)
        return;
    
    int cellIndex = face2Cells[index];
    int diagIndex = diagCSRIndex[cellIndex];
    int nNz = num_cells + 2 * num_surfaces;

    double internalCoeffx = internal_coeffs[num_boundary_surfaces * 0 + index];
    double internalCoeffy = internal_coeffs[num_boundary_surfaces * 1 + index];
    double internalCoeffz = internal_coeffs[num_boundary_surfaces * 2 + index];

    double boundaryCoeffx = boundary_coeffs[num_boundary_surfaces * 0 + index];
    double boundaryCoeffy = boundary_coeffs[num_boundary_surfaces * 1 + index];
    double boundaryCoeffz = boundary_coeffs[num_boundary_surfaces * 2 + index];

    atomicAdd(&A_csr[nNz * 0 + diagIndex], internalCoeffx);
    atomicAdd(&A_csr[nNz * 1 + diagIndex], internalCoeffy);
    atomicAdd(&A_csr[nNz * 2 + diagIndex], internalCoeffz);

    atomicAdd(&b[num_cells * 0 + cellIndex], boundaryCoeffx);
    atomicAdd(&b[num_cells * 1 + cellIndex], boundaryCoeffy);
    atomicAdd(&b[num_cells * 2 + cellIndex], boundaryCoeffz);
}

__global__ void ldu_to_csr_scalar_kernel(int nNz, const int *ldu_to_csr_index,
        const double *ldu, double *A_csr)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= nNz)
        return;

    int lduIndex = ldu_to_csr_index[index];
    double csrVal = ldu[lduIndex];
    A_csr[index] = csrVal;
}

__global__ void ldu_to_csr_kernel(int nNz, const int *ldu_to_csr_index, 
        const double *ldu, double *A_csr)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= nNz)
        return;
    
    int lduIndex = ldu_to_csr_index[index];
    double csrVal = ldu[lduIndex];
    A_csr[nNz * 0 + index] = csrVal;
    A_csr[nNz * 1 + index] = csrVal;
    A_csr[nNz * 2 + index] = csrVal;
}

__global__ void addAveInternaltoDiag(int num_cells, int num_boundary_surfaces, const int *face2Cells, 
        const double *internal_coeffs, double *A_pEqn)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_boundary_surfaces)
        return;

    int cellIndex = face2Cells[index];

    double internal_x = internal_coeffs[num_boundary_surfaces * 0 + index];
    double internal_y = internal_coeffs[num_boundary_surfaces * 1 + index];
    double internal_z = internal_coeffs[num_boundary_surfaces * 2 + index];

    double ave_internal = (internal_x + internal_y + internal_z) / 3;

    atomicAdd(&A_pEqn[cellIndex], ave_internal);
}

__global__ void addBoundaryDiag(int num_cells, int num_boundary_surfaces, const int *face2Cells, 
        const double *internal_coeffs, const double *psi, double *H_pEqn)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_boundary_surfaces)
        return;

    // addBoundaryDiag(boundaryDiagCmpt, cmpt); // add internal coeffs
    // boundaryDiagCmpt.negate();
    double internal_x = internal_coeffs[num_boundary_surfaces * 0 + index];
    double internal_y = internal_coeffs[num_boundary_surfaces * 1 + index];
    double internal_z = internal_coeffs[num_boundary_surfaces * 2 + index];

    // addCmptAvBoundaryDiag(boundaryDiagCmpt);
    double ave_internal = (internal_x + internal_y + internal_z) / 3;

    int cellIndex = face2Cells[index];

    // do not permute H anymore
    atomicAdd(&H_pEqn[num_cells * 0 + cellIndex], (-internal_x + ave_internal) * psi[num_cells * 0 + cellIndex]);
    atomicAdd(&H_pEqn[num_cells * 1 + cellIndex], (-internal_y + ave_internal) * psi[num_cells * 1 + cellIndex]);
    atomicAdd(&H_pEqn[num_cells * 2 + cellIndex], (-internal_z + ave_internal) * psi[num_cells * 2 + cellIndex]);
}

__global__ void lduMatrix_H(int num_cells, int num_surfaces,
        const int *lower_index, const int *upper_index, const double *lower, const double *upper,
        const double *psi, double *H_pEqn)
{
    /*
    for (label face=0; face<nFaces; face++)
    {
        HpsiPtr[uPtr[face]] -= lowerPtr[face]*psiPtr[lPtr[face]];
        HpsiPtr[lPtr[face]] -= upperPtr[face]*psiPtr[uPtr[face]];
    }*/
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_surfaces)
        return;
    
    int l = lower_index[index];
    int u = upper_index[index];

    atomicAdd(&H_pEqn[num_cells * 0 + u], -lower[index] * psi[num_cells * 0 + l]);
    atomicAdd(&H_pEqn[num_cells * 1 + u], -lower[index] * psi[num_cells * 1 + l]);
    atomicAdd(&H_pEqn[num_cells * 2 + u], -lower[index] * psi[num_cells * 2 + l]);
    atomicAdd(&H_pEqn[num_cells * 0 + l], -upper[index] * psi[num_cells * 0 + u]);
    atomicAdd(&H_pEqn[num_cells * 1 + l], -upper[index] * psi[num_cells * 1 + u]);
    atomicAdd(&H_pEqn[num_cells * 2 + l], -upper[index] * psi[num_cells * 2 + u]);
}

__global__ void addBoundarySrc_unCoupled(int num_cells, int num, int offset, 
        int num_boundary_surfaces, const int *face2Cells, const double *boundary_coeffs, double *H_pEqn)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num)
        return;

    int start_index = offset + index;

    // addBoundaryDiag(boundaryDiagCmpt, cmpt); // add internal coeffs
    // boundaryDiagCmpt.negate();
    double boundary_x = boundary_coeffs[num_boundary_surfaces * 0 + start_index];
    double boundary_y = boundary_coeffs[num_boundary_surfaces * 1 + start_index];
    double boundary_z = boundary_coeffs[num_boundary_surfaces * 2 + start_index];


    int cellIndex = face2Cells[start_index];

    // do not permute H anymore
    atomicAdd(&H_pEqn[num_cells * 0 + cellIndex], boundary_x);
    atomicAdd(&H_pEqn[num_cells * 1 + cellIndex], boundary_y);
    atomicAdd(&H_pEqn[num_cells * 2 + cellIndex], boundary_z);
}

__global__ void divideVol_permute_vec(int num_cells, const double *volume, double *H_pEqn, double *H_pEqn_perm)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_cells)
        return;
    
    // divide volume
    double vol = volume[index];
    double H_pEqn_x = H_pEqn[num_cells * 0 + index] / vol;
    double H_pEqn_y = H_pEqn[num_cells * 1 + index] / vol;
    double H_pEqn_z = H_pEqn[num_cells * 2 + index] / vol;

    // permute
    H_pEqn_perm[index * 3 + 0] = H_pEqn_x;
    H_pEqn_perm[index * 3 + 1] = H_pEqn_y;
    H_pEqn_perm[index * 3 + 2] = H_pEqn_z;
}

__global__ void solve_explicit_scalar_kernel(int num_cells, const double *diag, const double *source, double *psi)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_cells)
        return;
    
    psi[index] = source[index] / diag[index];
}

__global__ void lduMatrix_faceH(int num_surfaces,
        const int *lower_index, const int *upper_index, const double *lower, const double *upper,
        const double *psi, double *output)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_surfaces)
        return;
    
    int l = lower_index[index];
    int u = upper_index[index];

    output[index] = upper[index] * psi[u] - lower[index] * psi[l];    
}

__global__ void internal_contrib_for_flux(int num_boundary_surfaces, 
        const double *boundary_psi, const double *internal_coeffs, 
        const int *face2cells, double *boundary_output)
{
    int index = blockDim.x * blockIdx.x + threadIdx.x;
    if (index >= num_boundary_surfaces)
        return;

    int cellIndex = face2cells[index];
    boundary_output[index] = boundary_psi[cellIndex] * internal_coeffs[index];
}


void permute_vector_d2h(cudaStream_t stream, int num_cells, const double *input, double *output)
{
    size_t threads_per_block = 256;
    size_t blocks_per_grid = (num_cells + threads_per_block - 1) / threads_per_block;
    permute_vector_d2h_kernel<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, input, output);
}

void permute_vector_h2d(cudaStream_t stream, int num_cells, const double *input, double *output)
{
    size_t threads_per_block = 256;
    size_t blocks_per_grid = (num_cells + threads_per_block - 1) / threads_per_block;
    permute_vector_h2d_kernel<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, input, output);
}

void field_add_scalar(cudaStream_t stream,
        int num, const double *input1, const double *input2, double *output,
        int num_boundary_surfaces, const double *boundary_input1, const double *boundary_input2, double *boundary_output)
{
    TICK_INIT_EVENT;
    size_t threads_per_block = 256;
    size_t blocks_per_grid = (std::max(num, num_boundary_surfaces) + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    field_add_scalar_kernel<<<blocks_per_grid, threads_per_block, 0, stream>>>(num, num_boundary_surfaces,
            input1, input2, output, boundary_input1, boundary_input2, boundary_output);
    TICK_END_EVENT(field_add_scalar_kernel);
}

void field_add_vector(cudaStream_t stream,
        int num_cells, const double *input1, const double *input2, double *output,
        int num_boundary_surfaces, const double *boundary_input1, const double *boundary_input2, double *boundary_output, double sign)
{
    size_t threads_per_block = 256;
    size_t blocks_per_grid = (std::max(num_cells, num_boundary_surfaces) + threads_per_block - 1) / threads_per_block;

    field_add_vector_kernel<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, num_boundary_surfaces,
            input1, input2, output, boundary_input1, boundary_input2, boundary_output, sign);
}

void field_multiply_scalar(cudaStream_t stream,
        int num_cells, const double *input1, const double *input2, double *output,
        int num_boundary_surfaces, const double *boundary_input1, const double *boundary_input2, double *boundary_output)
{
    TICK_INIT_EVENT;
    size_t threads_per_block = 256;
    size_t blocks_per_grid = (std::max(num_cells, num_boundary_surfaces) + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    field_multiply_scalar_kernel<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, num_boundary_surfaces,
            input1, input2, output, boundary_input1, boundary_input2, boundary_output);
    TICK_END_EVENT(field_multiply_scalar_kernel);
}

void scalar_field_multiply_vector_field(cudaStream_t stream,
        int num_cells, const double *scalar_input, const double *vector_input, double *output,
        int num_boundary_surfaces, const double *scalar_boundary_input, const double *vector_boundary_input, double *boundary_output, double sign)
{
    size_t threads_per_block = 256;
    size_t blocks_per_grid = (std::max(num_cells, num_boundary_surfaces) + threads_per_block - 1) / threads_per_block;

    scalar_multiply_vector_kernel<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, num_boundary_surfaces,
            scalar_input, vector_input, output, scalar_boundary_input, vector_boundary_input, boundary_output);
}

void fvc_to_source_vector(cudaStream_t stream, int num_cells, const double *volume, const double *fvc_output, double *source)
{
    size_t threads_per_block = 256;
    size_t blocks_per_grid = (num_cells + threads_per_block - 1) / threads_per_block;
    fvc_to_source_vector_kernel<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells,
            volume, fvc_output, source);
}

void fvc_to_source_scalar(cudaStream_t stream, int num_cells, const double *volume, const double *fvc_output, double *source, double sign)
{
    TICK_INIT_EVENT;
    size_t threads_per_block = 256;
    size_t blocks_per_grid = (num_cells + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    fvc_to_source_scalar_kernel<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells,
            volume, fvc_output, source, sign);
    TICK_END_EVENT(fvc_to_source_scalar_kernel);
}

void ldu_to_csr_scalar(cudaStream_t stream, int num_cells, int num_surfaces, int num_boundary_surface,
        const int* boundary_cell_face, const int *ldu_to_csr_index, const int *diag_to_csr_index,
        double* ldu, double *source, // b = source
        const double *internal_coeffs, const double *boundary_coeffs,
        double *A)
{
    double *diag = ldu + num_surfaces;

    // add coeff to source and diagnal
    size_t threads_per_block = 256;
    size_t blocks_per_grid = (num_boundary_surface + threads_per_block - 1) / threads_per_block;
    addBoundaryDiagSrc_scalar<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_boundary_surface,
            boundary_cell_face, internal_coeffs, boundary_coeffs, diag, source);

    // construct csr
    int nNz = num_cells + 2 * num_surfaces;
    blocks_per_grid = (nNz + threads_per_block - 1) / threads_per_block;
    ldu_to_csr_scalar_kernel<<<blocks_per_grid, threads_per_block, 0, stream>>>(nNz, ldu_to_csr_index, ldu, A);
}

void ldu_to_csr(cudaStream_t stream, int num_cells, int num_surfaces, int num_boundary_surface,
        const int* boundary_cell_face, const int *ldu_to_csr_index, const int *diag_to_csr_index,
        const double *ldu, const double *internal_coeffs, const double *boundary_coeffs, double *source, double *A)
{
    TICK_INIT_EVENT;
    // construct diag
    int nNz = num_cells + 2 * num_surfaces;
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (nNz + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    ldu_to_csr_kernel<<<blocks_per_grid, threads_per_block, 0, stream>>>(nNz, ldu_to_csr_index, ldu, A);
    TICK_END_EVENT(ldu_to_csr_kernel);

    // add coeff to source and diagnal
    blocks_per_grid = (num_boundary_surface + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    addBoundaryDiagSrc<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, num_surfaces, num_boundary_surface, 
            boundary_cell_face, internal_coeffs, boundary_coeffs, diag_to_csr_index, A, source);
    TICK_END_EVENT(addBoundaryDiagSrc);
}

void update_boundary_coeffs_scalar(cudaStream_t stream,
        int num_patches, const int *patch_size, const int *patch_type,
        const double *boundary_delta_coeffs, const double *boundary_vf,
        double *value_internal_coeffs, double *value_boundary_coeffs,
        double *gradient_internal_coeffs, double *gradient_boundary_coeffs, const double *energy_gradient)
{
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = 1;

    int offset = 0;
    for (int i = 0; i < num_patches; i++) {
        threads_per_block = 256;
        blocks_per_grid = (patch_size[i] + threads_per_block - 1) / threads_per_block;
        // TODO: just basic patch type now
        // TODO: just vector version now
        if (patch_type[i] == boundaryConditions::zeroGradient) {
            update_boundary_coeffs_zeroGradient_scalar<<<blocks_per_grid, threads_per_block, 0, stream>>>(patch_size[i], offset,
                    value_internal_coeffs, value_boundary_coeffs, gradient_internal_coeffs, gradient_boundary_coeffs);
        } else if (patch_type[i] == boundaryConditions::fixedValue) {
            update_boundary_coeffs_fixedValue_scalar<<<blocks_per_grid, threads_per_block, 0, stream>>>(patch_size[i], offset,
                    boundary_vf, boundary_delta_coeffs, value_internal_coeffs, value_boundary_coeffs, gradient_internal_coeffs, gradient_boundary_coeffs);
        } else if (patch_type[i] == boundaryConditions::gradientEnergy) {
            update_boundary_coeffs_gradientEnergy_scalar<<<blocks_per_grid, threads_per_block, 0, stream>>>(patch_size[i], offset,
                    energy_gradient, boundary_delta_coeffs, value_internal_coeffs, value_boundary_coeffs, gradient_internal_coeffs, gradient_boundary_coeffs);
        }else {
            // xxx
            fprintf(stderr, "boundaryConditions other than zeroGradient are not support yet!\n");
        }
        offset += patch_size[i];
    }
}

void correct_boundary_conditions_scalar(cudaStream_t stream, ncclComm_t comm,
        const int *neighbor_peer, int num_boundary_surfaces, int num_patches,
        const int *patch_size, const int *patch_type,
        const int *boundary_cell_face, const double *vf, double *boundary_vf)
{
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = 1;

    int offset = 0;
    for (int i = 0; i < num_patches; i++) {
        threads_per_block = 256;
        blocks_per_grid = (patch_size[i] + threads_per_block - 1) / threads_per_block;
        if (patch_type[i] == boundaryConditions::zeroGradient) {
            correct_boundary_conditions_zeroGradient_scalar<<<blocks_per_grid, threads_per_block, 0, stream>>>(patch_size[i], offset,
                    vf, boundary_cell_face, boundary_vf);
        } else if (patch_type[i] == boundaryConditions::fixedValue
                    || patch_type[i] == boundaryConditions::calculated) {
            // No operation needed in this condition
        } else if (patch_type[i] == boundaryConditions::processor) {
            correct_boundary_conditions_processor_scalar(stream, comm, neighbor_peer[i], patch_size[i], offset, 
                    vf, boundary_cell_face, boundary_vf);
            offset += 2 * patch_size[i]; // patchNeighbourFields and patchInternalFields
            continue;
        } else {
            fprintf(stderr, "boundaryConditions other than zeroGradient are not support yet!\n");
        }
        offset += patch_size[i];
    }
}

void update_boundary_coeffs_vector(cudaStream_t stream, int num_boundary_surfaces, int num_patches,
        const int *patch_size, const int *patch_type, const double *boundary_vf, 
        const double *boundary_deltaCoeffs, const double *boundary_weight,
        double *value_internal_coeffs, double *value_boundary_coeffs,
        double *gradient_internal_coeffs, double *gradient_boundary_coeffs)
{
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = 1;

    int offset = 0;
    for (int i = 0; i < num_patches; i++) {
        threads_per_block = 256;
        blocks_per_grid = (patch_size[i] + threads_per_block - 1) / threads_per_block;
        // TODO: just basic patch type now
        // TODO: just vector version now
        if (patch_type[i] == boundaryConditions::zeroGradient) {
            update_boundary_coeffs_zeroGradient_vector<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_boundary_surfaces, patch_size[i], offset,
                    value_internal_coeffs, value_boundary_coeffs, gradient_internal_coeffs, gradient_boundary_coeffs);
        } else if (patch_type[i] == boundaryConditions::fixedValue) {
            update_boundary_coeffs_fixedValue_vector<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_boundary_surfaces, patch_size[i], offset,
                    boundary_vf, boundary_deltaCoeffs, value_internal_coeffs, value_boundary_coeffs, gradient_internal_coeffs, gradient_boundary_coeffs);
        } else if (patch_type[i] == boundaryConditions::processor) {
            update_boundary_coeffs_processor_vector<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_boundary_surfaces, patch_size[i], offset, 
                    boundary_weight, boundary_deltaCoeffs, 
                    value_internal_coeffs, value_boundary_coeffs, gradient_internal_coeffs, gradient_boundary_coeffs);
        } else {
            // xxx
            fprintf(stderr, "boundaryConditions other than zeroGradient are not support yet!\n");
        }
        offset += patch_size[i];
    }
}

void compute_upwind_weight(cudaStream_t stream, int num_surfaces, const double *phi, double *weight)
{
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_surfaces + threads_per_block - 1) / threads_per_block;
    // only need internal upwind-weight
    compute_upwind_weight_internal<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_surfaces, phi, weight);
}

void fvm_ddt_vol_scalar_vol_scalar(cudaStream_t stream, int num_cells, double rDeltaT,
        const double *rho, const double *rho_old, const double *vf, const double *volume,
        double *diag, double *source, double sign)
{
    TICK_INIT_EVENT;
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_cells + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    fvm_ddt_vol_scalar_vol_scalar_kernel<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells,
            rDeltaT, rho, rho_old, vf, volume, diag, source, sign);
    TICK_END_EVENT(fvm_ddt_vol_scalar_vol_scalar_kernel);
}

void fvm_ddt_scalar(cudaStream_t stream, int num_cells, double rDeltaT, 
        const double *vf_old, const double *volume, 
        double *diag, double *source, double sign)
{
#ifdef TIME_GPU
    printf("#############kernel profile#############\n");
#endif
    TICK_INIT_EVENT;
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_cells + threads_per_block - 1) / threads_per_block;
#ifdef TIME_GPU
    printf("warm up ...\n");
    warmup<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells);
#endif
    TICK_START_EVENT;
    fvm_ddt_scalar_kernel<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, 
            rDeltaT, vf_old, volume, diag, source, sign);
    TICK_END_EVENT(fvm_ddt_scalar_kernel);
}

void fvm_ddt_vector(cudaStream_t stream, int num_cells, double rDeltaT,
        const double *rho, const double *rho_old, const double *vf, const double *volume,
        double *diag, double *source, double sign)
{
    TICK_INIT_EVENT;
    size_t threads_per_block = 64;
    size_t blocks_per_grid = (num_cells + threads_per_block - 1) / threads_per_block;
#ifdef TIME_GPU
    printf("warm up ...\n");
    warmup<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells);
#endif
    TICK_START_EVENT;
    fvm_ddt_vector_kernel<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells,
            rDeltaT, rho, rho_old, vf, volume, diag, source, sign);
    TICK_END_EVENT(fvm_ddt_vector_kernel);
}

void fvm_div_scalar(cudaStream_t stream, int num_surfaces, const int *lowerAddr, const int *upperAddr,
        const double *phi, const double *weight,
        double *lower, double *upper, double *diag, // end for internal
        int num_patches, const int *patch_size, const int *patch_type,
        const double *boundary_phi, const double *value_internal_coeffs, const double *value_boundary_coeffs,
        double *internal_coeffs, double *boundary_coeffs, double sign)
{
    TICK_INIT_EVENT;
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_surfaces + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    fvm_div_scalar_internal<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_surfaces, lowerAddr, upperAddr,
            phi, weight, lower, upper, diag, sign);
    TICK_END_EVENT(fvm_div_scalar_internal);

    int offset = 0;
    for (int i = 0; i < num_patches; i++) {
        threads_per_block = 256;
        blocks_per_grid = (patch_size[i] + threads_per_block - 1) / threads_per_block;
        // TODO: just basic patch type now
        if (patch_type[i] == boundaryConditions::zeroGradient
                || patch_type[i] == boundaryConditions::fixedValue
                || patch_type[i] == boundaryConditions::gradientEnergy) {
            // TODO: just vector version now
            TICK_START_EVENT;
            fvm_div_scalar_boundary<<<blocks_per_grid, threads_per_block, 0, stream>>>(patch_size[i], offset,
                    boundary_phi, value_internal_coeffs, value_boundary_coeffs,
                    internal_coeffs, boundary_coeffs, sign);
            TICK_END_EVENT(fvm_div_scalar_boundary);
        } else {
            // xxx
            fprintf(stderr, "boundaryConditions other than zeroGradient are not support yet!\n");
        }
        offset += patch_size[i];
    }
}

void fvm_div_vector(cudaStream_t stream, int num_surfaces, int num_boundary_surfaces, 
        const int *lowerAddr, const int *upperAddr,
        const double *phi, const double *weight,
        double *lower, double *upper, double *diag, // end for internal
        int num_patches, const int *patch_size, const int *patch_type,
        const double *boundary_phi, const double *value_internal_coeffs, const double *value_boundary_coeffs,
        double *internal_coeffs, double *boundary_coeffs, double sign)
{
    TICK_INIT_EVENT;
    size_t threads_per_block = 256;
    size_t blocks_per_grid = (num_surfaces + threads_per_block - 1) / threads_per_block;
#ifdef TIME_GPU
    printf("warm up ...\n");
    warmup<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_surfaces);
#endif
    TICK_START_EVENT;
    fvm_div_vector_internal<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_surfaces, lowerAddr, upperAddr,
            phi, weight, lower, upper, diag, sign);
    TICK_END_EVENT(fvm_div_vector_internal);

    int offset = 0;
    for (int i = 0; i < num_patches; i++) {
        threads_per_block = 64;
        blocks_per_grid = (patch_size[i] + threads_per_block - 1) / threads_per_block;
        // TODO: just basic patch type now
        if (patch_type[i] == boundaryConditions::zeroGradient
                || patch_type[i] == boundaryConditions::fixedValue) {
            // TODO: just vector version now
            TICK_START_EVENT;
            fvm_div_vector_boundary<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_boundary_surfaces, patch_size[i], offset,
                    boundary_phi, value_internal_coeffs, value_boundary_coeffs,
                    internal_coeffs, boundary_coeffs, sign);
            TICK_END_EVENT(fvm_div_vector_boundary);
        } else {
            // xxx
            fprintf(stderr, "boundaryConditions other than zeroGradient are not support yet!\n");
        }
        offset += patch_size[i];
    }
}

void fvm_laplacian_scalar(cudaStream_t stream, int num_surfaces, int num_boundary_surfaces, 
        const int *lowerAddr, const int *upperAddr,
        const double *weight, const double *mag_sf, const double *delta_coeffs, const double *gamma,
        double *lower, double *upper, double *diag, // end for internal
        int num_patches, const int *patch_size, const int *patch_type,
        const double *boundary_mag_sf, const double *boundary_gamma,
        const double *gradient_internal_coeffs, const double *gradient_boundary_coeffs,
        double *internal_coeffs, double *boundary_coeffs, double sign)
{
    TICK_INIT_EVENT;
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_surfaces + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    fvm_laplacian_internal<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_surfaces, lowerAddr, upperAddr,
            weight, mag_sf, delta_coeffs, gamma, lower, upper, diag, sign);
    TICK_END_EVENT(fvm_laplacian_internal);
    int offset = 0;
    for (int i = 0; i < num_patches; i++) {
        threads_per_block = 256;
        blocks_per_grid = (patch_size[i] + threads_per_block - 1) / threads_per_block;
        // TODO: just basic patch type now
        if (patch_type[i] == boundaryConditions::zeroGradient
                || patch_type[i] == boundaryConditions::fixedValue
                || patch_type[i] == boundaryConditions::gradientEnergy) {
            // TODO: just vector version now
            TICK_START_EVENT;
            fvm_laplacian_scalar_boundary<<<blocks_per_grid, threads_per_block, 0, stream>>>(patch_size[i], offset,
                    boundary_mag_sf, boundary_gamma, gradient_internal_coeffs, gradient_boundary_coeffs,
                    internal_coeffs, boundary_coeffs, sign);
            TICK_END_EVENT(fvm_laplacian_scalar_boundary);
        } else {
            // xxx
            fprintf(stderr, "boundaryConditions other than zeroGradient are not support yet!\n");
        }
        offset += patch_size[i];
    }
}

void fvm_laplacian_vector(cudaStream_t stream, int num_surfaces, int num_boundary_surfaces, 
        const int *lowerAddr, const int *upperAddr,
        const double *weight, const double *mag_sf, const double *delta_coeffs, const double *gamma,
        double *lower, double *upper, double *diag, // end for internal
        int num_patches, const int *patch_size, const int *patch_type,
        const double *boundary_mag_sf, const double *boundary_gamma,
        const double *gradient_internal_coeffs, const double *gradient_boundary_coeffs,
        double *internal_coeffs, double *boundary_coeffs, double sign)
{
    TICK_INIT_EVENT;
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_surfaces + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    fvm_laplacian_internal<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_surfaces, lowerAddr, upperAddr,
            weight, mag_sf, delta_coeffs, gamma, lower, upper, diag, sign);
    TICK_END_EVENT(fvm_laplacian_internal);
    int offset = 0;
    for (int i = 0; i < num_patches; i++) {
        threads_per_block = 256;
        blocks_per_grid = (patch_size[i] + threads_per_block - 1) / threads_per_block;
        // TODO: just basic patch type now
        if (patch_type[i] == boundaryConditions::zeroGradient
                || patch_type[i] == boundaryConditions::fixedValue) {
            // TODO: just vector version now
            TICK_START_EVENT;
            fvm_laplacian_vector_boundary<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_boundary_surfaces, patch_size[i], offset,
                    boundary_mag_sf, boundary_gamma, gradient_internal_coeffs, gradient_boundary_coeffs,
                    internal_coeffs, boundary_coeffs, sign);
            TICK_END_EVENT(fvm_laplacian_vector_boundary);
        } else {
            // xxx
            fprintf(stderr, "boundaryConditions other than zeroGradient are not support yet!\n");
        }
        offset += patch_size[i];
    }
}

void fvm_laplacian_surface_scalar_vol_scalar(cudaStream_t stream, int num_surfaces, int num_boundary_surfaces, 
        const int *lowerAddr, const int *upperAddr,
        const double *mag_sf, const double *delta_coeffs, const double *gamma,
        double *lower, double *upper, double *diag, // end for internal
        const double *boundary_mag_sf, const double *boundary_gamma,
        const double *gradient_internal_coeffs, const double *gradient_boundary_coeffs,
        double *internal_coeffs, double *boundary_coeffs, double sign)
{
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_surfaces + threads_per_block - 1) / threads_per_block;
    fvm_laplacian_surface_scalar_internal<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_surfaces, lowerAddr, upperAddr,
            mag_sf, delta_coeffs, gamma, lower, upper, diag, sign);

    threads_per_block = 1024;
    blocks_per_grid = (num_boundary_surfaces + threads_per_block - 1) / threads_per_block;
    fvm_laplacian_surface_scalar_boundary<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_boundary_surfaces, 
            boundary_mag_sf, boundary_gamma, gradient_internal_coeffs, gradient_boundary_coeffs,
            internal_coeffs, boundary_coeffs, sign);
}

void fvc_ddt_vol_scalar_vol_scalar(cudaStream_t stream, int num_cells, double rDeltaT,
        const double *rho, const double *rho_old, const double *vf, const double *vf_old, const double *volume, 
        double *output, double sign)
{
    TICK_INIT_EVENT;
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_cells + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    fvc_ddt_vol_scalar_vol_scalar_kernel<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells,
            rDeltaT, rho, rho_old, vf, vf_old, volume, output, sign);
    TICK_END_EVENT(fvc_ddt_vol_scalar_vol_scalar_kernel);
}

void fvc_grad_vector(cudaStream_t stream, int num_cells, int num_surfaces, int num_boundary_surfaces,
        const int *lowerAddr, const int *upperAddr, 
        const double *weight, const double *Sf, const double *vf, double *output, // end for internal
        int num_patches, const int *patch_size, const int *patch_type,
        const int *boundary_cell_face, const double *boundary_vf, const double *boundary_Sf,
        const double *volume, const double *boundary_mag_Sf, double *boundary_output,
        const double *boundary_deltaCoeffs, double sign)
{
    TICK_INIT_EVENT;
    size_t threads_per_block = 32;
    size_t blocks_per_grid = (num_surfaces + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    fvc_grad_vector_internal<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, num_surfaces, lowerAddr, upperAddr,
            Sf, weight, vf, output);
    TICK_END_EVENT(fvc_grad_vector_internal);
    
    int offset = 0;
    // finish conctruct grad field except dividing cell volume
    for (int i = 0; i < num_patches; i++) {
        threads_per_block = 64;
        blocks_per_grid = (patch_size[i] + threads_per_block - 1) / threads_per_block;
        // TODO: just basic patch type now
        if (patch_type[i] == boundaryConditions::zeroGradient
                || patch_type[i] == boundaryConditions::fixedValue) {
            // TODO: just vector version now
            TICK_START_EVENT;
            fvc_grad_vector_boundary<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_boundary_surfaces, num_cells, 
                    patch_size[i], offset, boundary_cell_face,
                    boundary_Sf, boundary_vf, output);
            TICK_END_EVENT(fvc_grad_vector_boundary);
        } else {
            // xxx
            fprintf(stderr, "boundaryConditions other than zeroGradient are not support yet!\n");
        }
        offset += patch_size[i];
    }

    // divide cell volume
    threads_per_block = 512;
    blocks_per_grid = (num_cells + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    divide_cell_volume_tsr<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, volume, output);
    TICK_END_EVENT(divide_cell_volume_tsr);

    // correct boundary conditions
    offset = 0;
    for (int i = 0; i < num_patches; i++) {
        threads_per_block = 64;
        blocks_per_grid = (patch_size[i] + threads_per_block - 1) / threads_per_block;
        // TODO: just basic patch type now
        if (patch_type[i] == boundaryConditions::zeroGradient) {
            // TODO: just vector version now
            TICK_START_EVENT;
            fvc_grad_vector_correctBC_zeroGradient<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, num_boundary_surfaces,
                    patch_size[i], offset, boundary_cell_face,
                    output, boundary_vf, boundary_Sf, boundary_mag_Sf, boundary_output);
            TICK_END_EVENT(fvc_grad_vector_correctBC_zeroGradient);
        } else if (patch_type[i] == boundaryConditions::fixedValue) {
            // TODO: implement fixedValue version
            fvc_grad_vector_correctBC_fixedValue<<<blocks_per_grid, threads_per_block, 0, stream>>>(
                    num_cells, num_boundary_surfaces,
                    patch_size[i], offset, boundary_cell_face,
                    output, vf, boundary_Sf, boundary_mag_Sf, boundary_output, boundary_deltaCoeffs, boundary_vf);
        } else {
            // xxx
            fprintf(stderr, "boundaryConditions other than zeroGradient are not support yet!\n");
        }
        offset += patch_size[i];
    }
}

void scale_dev2T_tensor(cudaStream_t stream, int num_cells, const double *vf1, double *vf2,
        int num_boundary_surfaces, const double *boundary_vf1, double *boundary_vf2)
{
    TICK_INIT_EVENT;
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_cells + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    scale_dev2t_tensor_kernel<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, vf1, vf2);
    TICK_END_EVENT(scale_dev2t_tensor_kernel);

    blocks_per_grid = (num_boundary_surfaces + threads_per_block - 1) / threads_per_block;
    scale_dev2t_tensor_kernel<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_boundary_surfaces, boundary_vf1, boundary_vf2);
}

void fvc_div_surface_scalar(cudaStream_t stream, int num_cells, int num_surfaces, int num_boundary_surfaces,
        const int *lowerAddr, const int *upperAddr, const double *ssf, const int *boundary_cell_face,
        const double *boundary_ssf, const double *volume, double *output, double sign)
{
    TICK_INIT_EVENT;
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_surfaces + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    fvc_div_surface_scalar_internal<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_surfaces, lowerAddr, upperAddr, ssf, output, sign);
    TICK_END_EVENT(fvc_div_surface_scalar_internal);

    threads_per_block = 1024;
    blocks_per_grid = (num_boundary_surfaces + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    fvc_div_surface_scalar_boundary<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_boundary_surfaces, boundary_cell_face, 
            boundary_ssf, output, sign);
    TICK_END_EVENT(fvc_div_surface_scalar_boundary);
}

void fvc_div_cell_vector(cudaStream_t stream, int num_cells, int num_surfaces, int num_boundary_surfaces,
        const int *lowerAddr, const int *upperAddr, 
        const double *weight, const double *Sf, const double *vf, double *output, // end for internal
        int num_patches, const int *patch_size, const int *patch_type,
        const int *boundary_cell_face, const double *boundary_vf, const double *boundary_Sf,
        const double *volume, double sign)
{
    TICK_INIT_EVENT;
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_surfaces + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    fvc_div_cell_vector_internal<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, num_surfaces,
            lowerAddr, upperAddr, vf, weight, Sf, output, sign);
    TICK_END_EVENT(fvc_div_cell_vector_internal);

    int offset = 0;
    for (int i = 0; i < num_patches; i++) {
        threads_per_block = 256;
        blocks_per_grid = (patch_size[i] + threads_per_block - 1) / threads_per_block;
        // TODO: just basic patch type now
        if (patch_type[i] == boundaryConditions::zeroGradient
                || patch_type[i] == boundaryConditions::fixedValue
                || patch_type[i] == boundaryConditions::gradientEnergy) {
            // TODO: just vector version now
            TICK_START_EVENT;
            fvc_div_cell_vector_boundary<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_boundary_surfaces, patch_size[i], offset, boundary_cell_face,
                    boundary_Sf, boundary_vf, output, sign);
            TICK_END_EVENT(fvc_div_cell_vector_boundary);
        } else {
            // xxx
            fprintf(stderr, "boundaryConditions other than zeroGradient are not support yet!\n");
        }
        offset += patch_size[i];
    }
}

void fvc_div_cell_tensor(cudaStream_t stream, int num_cells, int num_surfaces, int num_boundary_surfaces, 
        const int *lowerAddr, const int *upperAddr,
        const double *weight, const double *Sf, const double *vf, double *output, // end for internal
        int num_patches, const int *patch_size, const int *patch_type,
        const int *boundary_cell_face, const double *boundary_vf, const double *boundary_Sf,
        const double *volume, double sign)
{
    TICK_INIT_EVENT;
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_surfaces + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    fvc_div_cell_tensor_internal<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, num_surfaces,
            lowerAddr, upperAddr, vf, weight, Sf, output, sign);
    TICK_END_EVENT(fvc_div_cell_tensor_internal);

    int offset = 0;
    for (int i = 0; i < num_patches; i++) {
        threads_per_block = 64;
        blocks_per_grid = (patch_size[i] + threads_per_block - 1) / threads_per_block;
        // TODO: just basic patch type now
        if (patch_type[i] == boundaryConditions::zeroGradient
                || patch_type[i] == boundaryConditions::fixedValue) {
            // TODO: just vector version now
            TICK_START_EVENT;
            fvc_div_cell_tensor_boundary<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, num_boundary_surfaces,
                    patch_size[i], offset, boundary_cell_face,
                    boundary_Sf, boundary_vf, output, sign);
            TICK_END_EVENT(fvc_div_cell_tensor_boundary);
        } else {
            // xxx
            fprintf(stderr, "boundaryConditions other than zeroGradient are not support yet!\n");
        }
        offset += patch_size[i];
    }
}

void fvc_div_surface_scalar_vol_scalar(cudaStream_t stream, int num_surfaces, 
        const int *lowerAddr, const int *upperAddr,
        const double *weight, const double *vf, const double *ssf, double *output, // end for internal
        int num_patches, const int *patch_size, const int *patch_type,
        const int *boundary_cell_face, const double *boundary_vf, const double *boundary_ssf, 
        double sign)
{
    TICK_INIT_EVENT;
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_surfaces + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    fvc_div_surface_scalar_vol_scalar_internal<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_surfaces,
            lowerAddr, upperAddr, weight, ssf, vf, output, sign);
    TICK_END_EVENT(fvc_div_surface_scalar_vol_scalar_internal);

    int offset = 0;
    for (int i = 0; i < num_patches; i++) {
        threads_per_block = 64;
        blocks_per_grid = (patch_size[i] + threads_per_block - 1) / threads_per_block;
        // TODO: just non-coupled patch type now
        if (patch_type[i] == boundaryConditions::zeroGradient
                || patch_type[i] == boundaryConditions::fixedValue
                || patch_type[i] == boundaryConditions::calculated) {
            TICK_START_EVENT;
            fvc_div_surface_scalar_vol_scalar_boundary<<<blocks_per_grid, threads_per_block, 0, stream>>>(patch_size[i], offset, boundary_cell_face,
                    boundary_vf, boundary_ssf, output, sign);
            TICK_END_EVENT(fvc_div_surface_scalar_vol_scalar_boundary);
        } else {
            // xxx
            fprintf(stderr, "boundaryConditions other than zeroGradient are not support yet!\n");
        }
        offset += patch_size[i];
    }
}

void fvc_grad_cell_scalar(cudaStream_t stream, int num_cells, int num_surfaces, int num_boundary_surfaces, 
        const int *lowerAddr, const int *upperAddr, 
        const double *weight, const double *Sf, const double *vf, double *output, // end for internal
        int num_patches, const int *patch_size, const int *patch_type,
        const int *boundary_cell_face, const double *boundary_vf, const double *boundary_Sf, const double *volume, double sign)
{
    TICK_INIT_EVENT;
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_surfaces + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    fvc_grad_scalar_internal<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, num_surfaces, lowerAddr, upperAddr,
            Sf, weight, vf, output, sign);
    TICK_END_EVENT(fvc_grad_scalar_internal);
    
    int offset = 0;
    for (int i = 0; i < num_patches; i++) {
        threads_per_block = 64;
        blocks_per_grid = (patch_size[i] + threads_per_block - 1) / threads_per_block;
        // TODO: just non-coupled patch type now
        if (patch_type[i] == boundaryConditions::zeroGradient
                || patch_type[i] == boundaryConditions::fixedValue) {
            TICK_START_EVENT;
            fvc_grad_scalar_boundary<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_boundary_surfaces, num_cells, patch_size[i], offset, boundary_cell_face,
                    boundary_Sf, boundary_vf, output, sign);
            TICK_END_EVENT(fvc_grad_scalar_boundary);
        } else {
            // xxx
            fprintf(stderr, "boundaryConditions other than zeroGradient are not support yet!\n");
        }
        offset += patch_size[i];
    }
}

void fvc_grad_cell_scalar_withBC(cudaStream_t stream, int num_cells, int num_surfaces, int num_boundary_surfaces,
        const int *lowerAddr, const int *upperAddr,
        const double *weight, const double *Sf, const double *vf, double *output, // end for internal
        int num_patches, const int *patch_size, const int *patch_type,
        const int *boundary_cell_face, const double *boundary_vf, const double *boundary_Sf,
        const double *volume, const double *boundary_mag_Sf, double *boundary_output,
        const double *boundary_deltaCoeffs)
{
    fvc_grad_cell_scalar(stream, num_cells, num_surfaces, num_boundary_surfaces, lowerAddr, upperAddr, weight, Sf, vf, output,
            num_patches, patch_size, patch_type, boundary_cell_face, boundary_vf, boundary_Sf, volume, 1.); // volume is no use here

    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_cells + threads_per_block - 1) / threads_per_block;
    divide_cell_volume_vec<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, volume, output);

    // correct boundary conditions
    int offset = 0;
    for (int i = 0; i < num_patches; i++) {
        threads_per_block = 256;
        blocks_per_grid = (patch_size[i] + threads_per_block - 1) / threads_per_block;
        // TODO: just basic patch type now
        if (patch_type[i] == boundaryConditions::zeroGradient) {
            // TODO: just vector version now
            fvc_grad_cell_scalar_correctBC_zeroGradient<<<blocks_per_grid, threads_per_block, 0, stream>>>(
                    num_cells, num_boundary_surfaces,
                    patch_size[i], offset, boundary_cell_face,
                    output, boundary_Sf, boundary_mag_Sf, boundary_output);
        } else if (patch_type[i] == boundaryConditions::fixedValue) {
            fvc_grad_cell_scalar_correctBC_fixedValue<<<blocks_per_grid, threads_per_block, 0, stream>>>(
                    num_cells, num_boundary_surfaces,
                    patch_size[i], offset, boundary_cell_face,
                    output, vf, boundary_Sf, boundary_mag_Sf, boundary_output, boundary_deltaCoeffs, boundary_vf);
        } else {
            // xxx
            fprintf(stderr, "boundaryConditions other than zeroGradient are not support yet!\n");
        }
        offset += patch_size[i];
    }

}

void fvc_laplacian_scalar(cudaStream_t stream, int num_cells, int num_surfaces, int num_boundary_surfaces,
        const int *lowerAddr, const int *upperAddr,
        const double *weight, const double *mag_sf, const double *delta_coeffs, const double *volume,
        const double *gamma, const double *vf, double *output, // end for internal
        int num_patches, const int *patch_size, const int *patch_type,
        const int *boundary_cell_face,
        const double *boundary_mag_sf, const double *boundary_delta_coeffs,
        const double *boundary_gamma, const double *boundary_vf, double sign)
{
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_surfaces + threads_per_block - 1) / threads_per_block;
    fvc_laplacian_scalar_internal<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_surfaces, lowerAddr, upperAddr,
            mag_sf, delta_coeffs, gamma, vf, output, sign);

    int offset = 0;
    for (int i = 0; i < num_patches; i++) {
        threads_per_block = 256;
        blocks_per_grid = (patch_size[i] + threads_per_block - 1) / threads_per_block;
        // TODO: just basic patch type now
        if (patch_type[i] == boundaryConditions::zeroGradient) {
            //fprintf(stderr, "patch_type is zeroGradient\n");
            // for zeroGradient, boundary_snGrad = 0, thus output += 0
        } else if (patch_type[i] == boundaryConditions::fixedValue) {
            //fprintf(stderr, "patch_type is fixedValue\n");
            // TODO: just vector version now
            fvc_laplacian_scalar_boundary_fixedValue<<<blocks_per_grid, threads_per_block, 0, stream>>>(
                    patch_size[i], offset, boundary_cell_face,
                    boundary_mag_sf, boundary_delta_coeffs, boundary_gamma, vf, boundary_vf, output, sign);
        } else {
            // xxx
            fprintf(stderr, "boundaryConditions other than zeroGradient are not support yet!\n");
        }
        offset += patch_size[i];
    }
}

void fvc_flux(cudaStream_t stream, int num_cells, int num_surfaces, int num_boundary_surfaces,
        const int *lowerAddr, const int *upperAddr, 
        const double *weight, const double *Sf, const double *vf, double *output, // end for internal
        int num_patches, const int *patch_size, const int *patch_type,
        const int *boundary_cell_face, const double *boundary_vf, const double *boundary_Sf, 
        double *boundary_output, double sign)
{
    TICK_INIT_EVENT;
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_surfaces + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    fvc_flux_internal_kernel<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, num_surfaces,
            lowerAddr, upperAddr, vf, weight, Sf, output, sign);
    TICK_END_EVENT(fvc_flux_internal_kernel);

    int offset = 0;
    for (int i = 0; i < num_patches; i++) {
        threads_per_block = 256;
        blocks_per_grid = (patch_size[i] + threads_per_block - 1) / threads_per_block;
        // TODO: maybe do not need loop boundarys
        if (patch_type[i] == boundaryConditions::zeroGradient
                || patch_type[i] == boundaryConditions::fixedValue
                || patch_type[i] == boundaryConditions::gradientEnergy) {
            TICK_START_EVENT;
            fvc_flux_boundary_kernel<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_boundary_surfaces, patch_size[i], offset, boundary_cell_face,
                    boundary_Sf, boundary_vf, boundary_output, sign);
            TICK_END_EVENT(fvc_flux_boundary_kernel);
        } else {
            // xxx
            fprintf(stderr, "boundaryConditions other than zeroGradient are not support yet!\n");
        }
        offset += patch_size[i];
    }
}

void fvc_interpolate(cudaStream_t stream, int num_cells, int num_surfaces,
        const int *lowerAddr, const int *upperAddr, 
        const double *weight, const double *vf, double *output, // end for internal
        int num_patches, const int *patch_size, const int *patch_type,
        const double *boundary_vf, double *boundary_output, double sign)
{
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_surfaces + threads_per_block - 1) / threads_per_block;
    fvc_interpolate_internal_kernel<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_surfaces,
            lowerAddr, upperAddr, vf, weight, output, sign);
    
    int offset = 0;
    for (int i = 0; i < num_patches; i++) {
        threads_per_block = 256;
        blocks_per_grid = (patch_size[i] + threads_per_block - 1) / threads_per_block;
        // TODO: maybe do not need loop boundarys
        if (patch_type[i] == boundaryConditions::zeroGradient
                || patch_type[i] == boundaryConditions::fixedValue
                || patch_type[i] == boundaryConditions::gradientEnergy) {
            fvc_interpolate_boundary_kernel_upCouple<<<blocks_per_grid, threads_per_block, 0, stream>>>(patch_size[i], offset,
                    boundary_vf, boundary_output, sign);
        } else {
            // xxx
            fprintf(stderr, "boundaryConditions other than zeroGradient are not support yet!\n");
        }
        offset += patch_size[i];
    }
}

void fvc_ddt_scalar(cudaStream_t stream, int num_cells, double rDeltaT,
        const double *vf, const double *vf_old, const double *volume, double *source, double sign)
{
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_cells + threads_per_block - 1) / threads_per_block;
    fvc_ddt_scalar_kernel<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, vf, vf_old, rDeltaT, volume, source, sign);
}

void fvc_ddt_scalar_field(cudaStream_t stream, int num_cells, double rDeltaT,
        const double *vf, const double *vf_old, const double *volume, double *source, double sign)
{
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_cells + threads_per_block - 1) / threads_per_block;
    fvc_ddt_scalar_field_kernel<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, vf, vf_old, rDeltaT, volume, source, sign);
}

void fvMtx_A(cudaStream_t stream, int num_cells, int num_surfaces, int num_boundary_surfaces,
        const int *boundary_cell_face, const double *internal_coeffs, const double *volume, const double *diag, 
        double *A_pEqn)
{
    checkCudaErrors(cudaMemcpyAsync(A_pEqn, diag, num_cells * sizeof(double), cudaMemcpyDeviceToDevice, stream));
    TICK_INIT_EVENT;

    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_boundary_surfaces + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    addAveInternaltoDiag<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, num_boundary_surfaces, boundary_cell_face, 
            internal_coeffs, A_pEqn);
    TICK_END_EVENT(addAveInternaltoDiag);
    
    blocks_per_grid = (num_cells + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    divide_cell_volume_scalar<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, volume, A_pEqn);
    TICK_END_EVENT(divide_cell_volume_scalar);
}

void fvMtx_H(cudaStream_t stream, int num_cells, int num_surfaces, int num_boundary_surfaces, 
        const int *lowerAddr, const int *upperAddr, const double *volume,
        int num_patches, const int *patch_size, const int *patch_type,
        const int *boundary_cell_face, const double *internal_coffs, const double *boundary_coeffs, 
        const double *lower, const double *upper, const double *source, const double *psi, 
        double *H_pEqn, double *H_pEqn_perm)
{
    TICK_INIT_EVENT;
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_boundary_surfaces + threads_per_block - 1) / threads_per_block;

    TICK_START_EVENT;
    checkCudaErrors(cudaMemcpyAsync(H_pEqn, source, num_cells * 3 * sizeof(double), cudaMemcpyDeviceToDevice, stream));
    addBoundaryDiag<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, num_boundary_surfaces, boundary_cell_face, 
            internal_coffs, psi, H_pEqn);
    TICK_END_EVENT(addBoundaryDiag);
    
    blocks_per_grid = (num_surfaces + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    lduMatrix_H<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, num_surfaces, lowerAddr, upperAddr, 
            lower, upper, psi, H_pEqn);
    TICK_END_EVENT(lduMatrix_H);

    int offset = 0;
    for (int i = 0; i < num_patches; i++) {
        threads_per_block = 64;
        blocks_per_grid = (patch_size[i] + threads_per_block - 1) / threads_per_block;
        // TODO: just non-coupled patch type now
        if (patch_type[i] == boundaryConditions::zeroGradient
                || patch_type[i] == boundaryConditions::fixedValue) {
            TICK_START_EVENT;
            addBoundarySrc_unCoupled<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, patch_size[i], offset, 
                    num_boundary_surfaces, boundary_cell_face, boundary_coeffs, H_pEqn);
            TICK_END_EVENT(addBoundarySrc_unCoupled);
        } else {
            // xxx
            fprintf(stderr, "boundaryConditions other than zeroGradient are not support yet!\n");
        }
        offset += patch_size[i];
    }
    blocks_per_grid = (num_cells + threads_per_block - 1) / threads_per_block;
    TICK_START_EVENT;
    divideVol_permute_vec<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, volume, H_pEqn, H_pEqn_perm);
    TICK_END_EVENT(divideVol_permute_vec);
}

void fvMtx_flux(cudaStream_t stream, int num_surfaces, int num_boundary_surfaces, 
        const int *lowerAddr, const int *upperAddr, const double *lower, const double *upper,
        const double *psi, double *output, //end for internal
        int num_patches, const int *patch_size, const int *patch_type,
        const int *boundary_cell_face, const double *internal_coeffs, const double *boundary_coeffs, 
        const double *boundary_psi, double *boundary_output)
{
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_surfaces + threads_per_block - 1) / threads_per_block;
    lduMatrix_faceH<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_surfaces, lowerAddr, upperAddr, lower, upper, psi, output);

    blocks_per_grid = (num_boundary_surfaces + threads_per_block - 1) / threads_per_block;
    internal_contrib_for_flux<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_boundary_surfaces, boundary_psi, internal_coeffs,
            boundary_cell_face, boundary_output);
    
    int offset = 0;
    for (int i = 0; i < num_patches; i++) {
        threads_per_block = 64;
        blocks_per_grid = (patch_size[i] + threads_per_block - 1) / threads_per_block;
        // TODO: coupled conditions
        if (patch_type[i] == boundaryConditions::coupled) {
            // coupled conditions
        } else {
            // xxx
        }
        offset += patch_size[i];
    }
}

void solve_explicit_scalar(cudaStream_t stream, int num_cells, const double *diag, const double *source,
        double *psi)
{
    TICK_INIT_EVENT;
    size_t threads_per_block = 1024;
    size_t blocks_per_grid = (num_cells + threads_per_block - 1) / threads_per_block;

    TICK_START_EVENT;
    solve_explicit_scalar_kernel<<<blocks_per_grid, threads_per_block, 0, stream>>>(num_cells, diag, source, psi);
    TICK_END_EVENT(solve_explicit_scalar_kernel);
}
