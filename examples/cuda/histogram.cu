/*******************************************************
 * Copyright (c) 2015-2019, ArrayFire
 * All rights reserved.
 *
 * This file is distributed under 3-clause BSD license.
 * The complete license agreement can be obtained at:
 * http://arrayfire.com/licenses/BSD-3-Clause
 ********************************************************/

#include <forge.h>
#include <cuda_runtime.h>
#include <curand.h>
#include <curand_kernel.h>
#include <cuComplex.h>
#include <CUDACopy.hpp>
#include <cstdio>

const unsigned IMGW = 256;
const unsigned IMGH = 256;
const unsigned DIMX = 1000;
const unsigned DIMY = 800;
const unsigned WIN_ROWS = 1;
const unsigned WIN_COLS = 2;
const unsigned NBINS = 256;

curandState_t* state;

struct Bitmap {
    unsigned char *ptr;
    unsigned width;
    unsigned height;
};

class PerlinNoise
{
    public:
        float* base;
        float* perlin;

        PerlinNoise();
        ~PerlinNoise();
        void generateNoise();
};

Bitmap createBitmap(unsigned w, unsigned h);

void destroyBitmap(Bitmap& bmp);

void kernel(Bitmap& bmp, PerlinNoise& pn);

void populateBins(Bitmap& bmp, int *hist_array, const unsigned nbins, float *hist_cols);

__global__
void setupRandomKernel(curandState *states, unsigned long long seed)
{
    unsigned tid = blockDim.x * blockIdx.x + threadIdx.x;
    curand_init(seed, tid, 0, &states[tid]);
}

int main(void)
{
    Bitmap bmp = createBitmap(IMGW, IMGH);

    FORGE_CUDA_CHECK(cudaMalloc((void **)&state, NBINS*sizeof(curandState_t)));
    setupRandomKernel <<< 1, NBINS >>> (state, 314567);

    /*
     * First Forge call should be a window creation call
     * so that necessary OpenGL context is created for any
     * other fg::* object to be created successfully
     */
    fg::Window wnd(DIMX, DIMY, "Histogram Demo");
    wnd.makeCurrent();

    /*
     * Split the window into grid regions
     */
    wnd.grid(WIN_ROWS, WIN_COLS);

    fg::Image img(IMGW, IMGH, FG_RGBA, fg::u8);

    fg::Chart chart(FG_CHART_2D);
    /* set x axis limits to maximum and minimum values of data
     * and y axis limits to range [0, number of pixels ideally]
     * but practically total number of pixels as y range will skew
     * the histogram graph vertically. Therefore setting it to
     * 25% of total number of pixels */
    chart.setAxesLimits(0, 1, 0, IMGW*IMGH/(float)(NBINS/4.0));

    /*
     * Create histogram object specifying number of bins
     */
    fg::Histogram hist = chart.histogram(NBINS, fg::s32);
    /*
     * Set histogram colors
     */
    hist.setColor(FG_YELLOW);

    PerlinNoise noiseGenerator;
    int *histOut;
    float *histColors;

    FORGE_CUDA_CHECK(cudaMalloc((void**)&histOut, NBINS * sizeof(int)));
    FORGE_CUDA_CHECK(cudaMalloc((void**)&histColors, 3*NBINS * sizeof(float)));

    unsigned frame = 0;
    do {
        if (frame%8==0) {
            kernel(bmp, noiseGenerator);
            fg::copy(img, bmp.ptr);

            populateBins(bmp, histOut, NBINS, histColors);

            fg::copy(hist.vertices(), histOut);
            fg::copy(hist.colors(), histColors);
            frame = 0;
        }

        wnd.draw(0, 0, img,  "Dynamic Perlin Noise" );
        wnd.draw(1, 0, chart, "Histogram of Noisy Image");

        wnd.swapBuffers();
        frame++;
    } while(!wnd.close());

    FORGE_CUDA_CHECK(cudaFree(histOut));
    FORGE_CUDA_CHECK(cudaFree(histColors));
    return 0;
}

Bitmap createBitmap(unsigned w, unsigned h)
{
    Bitmap retVal;
    retVal.width = w;
    retVal.height= h;
    FORGE_CUDA_CHECK(cudaMalloc((void**)&retVal.ptr, sizeof(unsigned char)*4*w*h));
    return retVal;
}

void destroyBitmap(Bitmap& bmp)
{
    FORGE_CUDA_CHECK(cudaFree(bmp.ptr));
}

PerlinNoise::PerlinNoise()
{
    const size_t IMG_SIZE = IMGW*IMGH*sizeof(float);

    FORGE_CUDA_CHECK(cudaMalloc((void**)&base, IMG_SIZE));
    FORGE_CUDA_CHECK(cudaMalloc((void**)&perlin, IMG_SIZE));
}

PerlinNoise::~PerlinNoise()
{
    FORGE_CUDA_CHECK(cudaFree(base));
    FORGE_CUDA_CHECK(cudaFree(perlin));
}

inline
int divup(int a, int b)
{
    return (a+b-1)/b;
}

__device__
float interp(float x0, float x1, float alpha)
{
    return x0 * (1 - alpha) + alpha * x1;
}

__global__
void perlinInitKernel(float* base, float* perlin, curandState* state)
{
    int x = blockIdx.x * blockDim.x  + threadIdx.x;
    int y = blockIdx.y * blockDim.y  + threadIdx.y;

    if (x<IMGW && y<IMGH) {
        int index = y*IMGW + x;
        base[index] = curand_uniform(&state[index%NBINS]);
        perlin[index] = 0.0f;
    }
}

__global__
void perlinComputeKernel(float* perlin, float* base, float amp, int period)
{
    uint x = blockIdx.x * blockDim.x  + threadIdx.x;
    uint y = blockIdx.y * blockDim.y  + threadIdx.y;

    if (x<IMGW && y<IMGH) {
        int index  = y*IMGW + x;

        float freq = 1.0f / period;

        int si0 = (x/period) * period;
        int si1 = (si0 + period) % IMGW;
        float hblend = (x - si0) * freq;

        int sj0 = (y/period) * period;
        int sj1 = (sj0 + period) % IMGH;
        float vblend = (y - sj0) * freq;

        float top = interp(base[si0+IMGW*sj0], base[si1+IMGW*sj0], hblend);
        float bot = interp(base[si0+IMGW*sj1], base[si1+IMGW*sj1], hblend);

        perlin[index] += (amp * interp(top, bot, vblend));
    }
}

__global__
void perlinNormalize(float* perlin, float tamp)
{
    int x = blockIdx.x * blockDim.x  + threadIdx.x;
    int y = blockIdx.y * blockDim.y  + threadIdx.y;

    if (x<IMGW && y<IMGH) {
        int index = y*IMGW + x;
        perlin[index] = perlin[index]/tamp;
    }
}

void PerlinNoise::generateNoise()
{
    static dim3 threads(32, 8);
    dim3 blocks(divup(IMGW, threads.x), divup(IMGH, threads.y));

    float persistence = 0.5f;
    float amp  = 1.0f;
    float tamp = 0.0f;

    perlinInitKernel<<< blocks, threads >>> (base, perlin, state);

    for (int octave=6; octave>=0; --octave) {
        int period = 1 << octave;

        perlinComputeKernel<<< blocks, threads >>>(perlin, base, amp, period);

        tamp += amp;
        amp *= persistence;
    }

    perlinNormalize<<< blocks, threads >>>(perlin, tamp);
}

__global__
void fillImageKernel(unsigned char* ptr, unsigned width, unsigned height, float* perlin)
{
    int x = blockIdx.x * blockDim.x  + threadIdx.x;
    int y = blockIdx.y * blockDim.y  + threadIdx.y;

    if (x<width && y<height) {
        int offset  = x + y * width;

        unsigned u = (unsigned)(IMGW*x/(float)(width));
        unsigned v = (unsigned)(IMGH*y/(float)(height));
        int idx = u + v*IMGW;

        unsigned char val = 255 * perlin[idx];
        ptr[offset*4 + 0] = val;
        ptr[offset*4 + 1] = val;
        ptr[offset*4 + 2] = val;
        ptr[offset*4 + 3] = 255;
    }
}

void kernel(Bitmap& bmp, PerlinNoise& pn)
{
    static dim3 threads(32, 8);

    pn.generateNoise();

    dim3 blocks(divup(bmp.width, threads.x), divup(bmp.height, threads.y));

    fillImageKernel<<< blocks, threads >>>(bmp.ptr, bmp.width, bmp.height, pn.perlin);
}

__global__
void histogramKernel(const unsigned char* perlinNoise, int* histOut, const unsigned nbins)
{
    int x = blockIdx.x * blockDim.x  + threadIdx.x;
    int y = blockIdx.y * blockDim.y  + threadIdx.y;

    if (x<IMGW && y<IMGH) {
        int offset  = y * IMGW + x;
        unsigned char noiseVal = perlinNoise[offset*4 + 0];
        offset = __float2int_rd(nbins * (__int2float_rd(noiseVal)/255.f));
        atomicAdd(histOut + offset , 1);
    }
}

__global__
void histColorsKernel(float* histColors, curandState *states)
{
    int bin = blockIdx.x * blockDim.x  + threadIdx.x;

    histColors[3*bin+0] = curand_uniform(&states[bin]);
    histColors[3*bin+1] = curand_uniform(&states[bin]);
    histColors[3*bin+2] = curand_uniform(&states[bin]);
}

void populateBins(Bitmap& bmp, int *histOut, const unsigned nbins, float *histColors)
{
    static const dim3 threads(8, 8);
    dim3 blocks(divup(bmp.width, threads.x),
                divup(bmp.height, threads.y));

    cudaMemset(histOut, 0, nbins * sizeof(int));

    histogramKernel<<< blocks, threads >>>(bmp.ptr, histOut, nbins);

    histColorsKernel<<< 1, nbins >>>(histColors, state);
}
