//
// This software contains source code provided by NVIDIA Corporation.
//

#ifdef HAVE_CONFIG_H
#include "vvconfig.h"
#endif

#if defined(HAVE_CUDA) && defined(NV_PROPRIETARY_CODE)

#include "vvcudautils.h"
#include "vvdebugmsg.h"
#include "vvglew.h"
#include "vvgltools.h"
#include "vvrayrend.h"

#include <cuda.h>
#include <cuda_runtime_api.h>
#include <cuda_gl_interop.h>
#include <ctime>
#include <iostream>

using std::cerr;
using std::endl;

texture<uchar, 3, cudaReadModeNormalizedFloat> volTexture8;
texture<ushort, 3, cudaReadModeNormalizedFloat> volTexture16;
texture<float4, 1, cudaReadModeElementType> tfTexture;
texture<float4, 1, cudaReadModeElementType> randTexture;

const int NUM_RAND_VECS = 8192;

int iDivUp(const int a, const int b)
{
  return (a % b != 0) ? (a / b + 1) : (a / b);
}

typedef struct
{
  float m[4][4];
} matrix4x4;

__constant__ matrix4x4 c_invViewMatrix;

struct Ray
{
  float3 o;
  float3 d;
};

template<int bpc>
__device__ float volume(const float x, const float y, const float z)
{
  if (bpc == 1)
  {
    return tex3D(volTexture8, x, y, z);
  }
  else if (bpc == 2)
  {
    return tex3D(volTexture16, x, y, z);
  }
  else
  {
    return -1.0f;
  }
}

template<int bpc>
__device__ float volume(const float3& pos)
{
  if (bpc == 1)
  {
    return tex3D(volTexture8, pos.x, pos.y, pos.z);
  }
  else if (bpc == 2)
  {
    return tex3D(volTexture16, pos.x, pos.y, pos.z);
  }
  else
  {
    return -1.0f;
  }
}

__device__ float3 calcTexCoord(const float3& pos, const float3& volSizeHalf)
{
  return make_float3((pos.x + volSizeHalf.x) / (volSizeHalf.x * 2.0f),
                     (pos.y + volSizeHalf.y) / (volSizeHalf.y * 2.0f),
                     (pos.z + volSizeHalf.z) / (volSizeHalf.z * 2.0f));
}

__device__ bool solveQuadraticEquation(const float A, const float B, const float C,
                                       float* tnear, float* tfar)
{
  const float discrim = B * B - 4.0f * A * C;
  if (discrim < 0.0f)
  {
    *tnear = -1.0f;
    *tfar = -1.0f;
  }
  const float rootDiscrim = __fsqrt_rn(discrim);
  float q;
  if (B < 0)
  {
    q = -0.5f * (B - rootDiscrim);
  }
  else
  {
    q = -0.5f * (B + rootDiscrim);
  }
  *tnear = q / A;
  *tfar = C / q;
  if (*tnear > *tfar)
  {
    float tmp = *tnear;
    *tnear = *tfar;
    *tfar = tmp;
    return true;
  }
  return false;
}

__device__ bool intersectBox(const Ray& ray, const float3& boxmin, const float3& boxmax,
                             float* tnear, float* tfar)
{
  // compute intersection of ray with all six bbox planes
  float3 invR = make_float3(1.0f, 1.0f, 1.0f) / ray.d;
  float t1 = (boxmin.x - ray.o.x) * invR.x;
  float t2 = (boxmax.x - ray.o.x) * invR.x;
  float tmin = fminf(t1, t2);
  float tmax = fmaxf(t1, t2);

  t1 = (boxmin.y - ray.o.y) * invR.y;
  t2 = (boxmax.y - ray.o.y) * invR.y;
  tmin = fmaxf(fminf(t1, t2), tmin);
  tmax = fminf(fmaxf(t1, t2), tmax);

  t1 = (boxmin.z - ray.o.z) * invR.z;
  t2 = (boxmax.z - ray.o.z) * invR.z;
  tmin = fmaxf(fminf(t1, t2), tmin);
  tmax = fminf(fmaxf(t1, t2), tmax);

  *tnear = tmin;
  *tfar = tmax;

  return ((tmax >= tmin) && (tmax >= 0.0f));
}

__device__ bool intersectSphere(const Ray& ray, const float3& center, const float radiusSqr,
                                float* tnear, float* tfar)
{
  Ray r = ray;
  r.o -= center;
  float A = r.d.x * r.d.x + r.d.y * r.d.y
          + r.d.z * r.d.z;
  float B = 2 * (r.d.x * r.o.x + r.d.y * r.o.y
               + r.d.z * r.o.z);
  float C = r.o.x * r.o.x + r.o.y * r.o.y
          + r.o.z * r.o.z - radiusSqr;
  return solveQuadraticEquation(A, B, C, tnear, tfar);
}

__device__ void intersectPlane(const Ray& ray, const float3& normal, const float& dist,
                               float* nddot, float* tnear)
{
  *nddot = dot(normal, ray.d);
  const float vOrigin = dist - dot(normal, ray.o);
  *tnear = vOrigin / *nddot;
}


__device__ float4 mul(const matrix4x4& M, const float4& v)
{
  float4 result;
  result.x = M.m[0][0] * v.x + M.m[0][1] * v.y + M.m[0][2] * v.z + M.m[0][3] * v.w;
  result.y = M.m[1][0] * v.x + M.m[1][1] * v.y + M.m[1][2] * v.z + M.m[1][3] * v.w;
  result.z = M.m[2][0] * v.x + M.m[2][1] * v.y + M.m[2][2] * v.z + M.m[2][3] * v.w;
  result.w = M.m[3][0] * v.x + M.m[3][1] * v.y + M.m[3][2] * v.z + M.m[3][3] * v.w;
  return result;
}

__device__ float3 perspectiveDivide(const float4& v)
{
  const float wInv = 1.0f / v.w;
  return make_float3(v.x * wInv, v.y * wInv, v.z * wInv);
}

__device__ uint rgbaFloatToInt(float4 rgba)
{
  clamp(rgba.x);
  clamp(rgba.y);
  clamp(rgba.z);
  clamp(rgba.w);
  return (uint(rgba.w*255)<<24) | (uint(rgba.z*255)<<16) | (uint(rgba.y*255)<<8) | uint(rgba.x*255);
}

__device__ uint rgbaFloatToInt(float3 rgb)
{
  float4 rgba = make_float4(rgb.x, rgb.y, rgb.z, 1.0f);
  return rgbaFloatToInt(rgba);
}

template<int bpc>
__device__ float3 gradient(const float3& pos)
{
  const float DELTA = 0.01f;

  float3 sample1;
  float3 sample2;

  sample1.x = volume<bpc>(pos - make_float3(DELTA, 0.0f, 0.0f));
  sample2.x = volume<bpc>(pos + make_float3(DELTA, 0.0f, 0.0f));
  sample1.y = volume<bpc>(pos - make_float3(0.0f, DELTA, 0.0f));
  sample2.y = volume<bpc>(pos + make_float3(0.0f, DELTA, 0.0f));
  sample1.z = volume<bpc>(pos - make_float3(0.0f, 0.0f, DELTA));
  sample2.z = volume<bpc>(pos + make_float3(0.0f, 0.0f, DELTA));

  return sample2 - sample1;
}

template<int bpc>
__device__ float4 blinnPhong(const float4& classification, const float3& pos,
                             const float3& L, const float3& H,
                             const float3& Ka, const float3& Kd, const float3& Ks,
                             const float shininess,
                             const float3* normal = NULL)
{
  float3 N = normalize(gradient<bpc>(pos));

  if (normal != NULL)
  {
    // Interpolate gradient with normal from clip object (based on opacity).
    N = (*normal * classification.w) + (N * (1.0f - classification.w));
    N = normalize(N);
  }

  const float diffuse = fabsf(dot(L, N));
  const float specular = powf(dot(H, N), shininess);

  const float3 c = make_float3(classification);
  float3 tmp = Ka * c + Kd * diffuse * c;
  if (specular > 0.0f)
  {
    tmp += Ks * specular * c;
  }
  return make_float4(tmp.x, tmp.y, tmp.z, classification.w);
}

template<
         bool earlyRayTermination,
         bool frontToBack,
         int bpc,
         int mipMode,
         bool lighting,
         bool opacityCorrection,
         bool jittering,
         bool clipSphere,
         bool clipPlane,
         bool useSphereAsProbe
        >
__global__ void render(uint *d_output, const uint width, const uint height, const float dist,
                       const float3 volSizeHalf, const float3 L, const float3 H,
                       const float3 sphereCenter, const float sphereRadius,
                       const float3 planeNormal, const float planeDist)
{
  const int maxSteps = INT_MAX;
  const float tstep = dist;
  const float opacityThreshold = 0.95f;

  const uint x = blockIdx.x * blockDim.x + threadIdx.x;
  const uint y = blockIdx.y * blockDim.y + threadIdx.y;

  if ((x >= width) || (y >= height))
  {
    return;
  }

  const float u = (x / static_cast<float>(width)) * 2.0f - 1.0f;
  const float v = (y / static_cast<float>(height)) * 2.0f - 1.0f;

  /*
   * Rays like if the view were orthographic with origins over each pixel.
   * These are multiplied with the inverse modelview projection matrix.
   * First of all, the rays will be transformed to fit to the frustum.
   * Then the rays will be oriented so that they can hit the volume.
   */
  const float4 o = mul(c_invViewMatrix, make_float4(u, v, -1.0f, 1.0f));
  const float4 d = mul(c_invViewMatrix, make_float4(u, v, 1.0f, 1.0f));

  Ray ray;
  ray.o = perspectiveDivide(o);
  ray.d = perspectiveDivide(d);
  ray.d = ray.d - ray.o;
  ray.d = normalize(ray.d);

  float tnear;
  float tfar;
  const bool hit = intersectBox(ray, -volSizeHalf, volSizeHalf, &tnear, &tfar);
  if (!hit)
  {
    d_output[y * width + x] = 0;
    return;
  }

  if (tnear < 0.0f)
  {
    tnear = 0.0f;
  }

  // Calc hits with clip sphere.
  float tsnear;
  float tsfar;
  if (clipSphere)
  {
    // In probe mode, rays that don't hit the sphere simply aren't rendered.
    // In ordinary sphere mode, the intersection data is memorized.
    if (!intersectSphere(ray, sphereCenter, sphereRadius, &tsnear, &tsfar) && useSphereAsProbe)
    {
      d_output[y * width + x] = 0;
      return;
    }
  }

  // Calc hits with clip plane.
  float tpnear;
  float nddot;
  if (clipPlane)
  {
    intersectPlane(ray, planeNormal, planeDist, &nddot, &tpnear);
  }

  float4 dst = make_float4(0.0f);
  float t = tnear;
  float3 pos = ray.o + ray.d * tnear;

  if (jittering)
  {
    const float4 randOffset = tex1D(randTexture, (y * width + x) % NUM_RAND_VECS);
    pos += make_float3(randOffset);
  }
  const float3 step = ray.d * tstep;

  float maxIntensity = 0.0f;
  float minIntensity = FLT_MAX;

  // If just clipped, shade with the normal of the clipping surface.
  bool justClippedPlane = false;
  bool justClippedSphere = false;

  for (int i=0; i<maxSteps; ++i)
  {
    // Test for clipping.
    const bool clippedPlane = (clipPlane && (((t <= tpnear) && (nddot >= 0.0f))
                                          || ((t >= tpnear) && (nddot < 0.0f))));
    const bool clippedSphere = useSphereAsProbe ? (clipSphere && ((t < tsnear) || (t > tsfar)))
                                                : (clipSphere && (t >= tsnear) && (t <= tsfar));

    if (clippedPlane || clippedSphere)
    {
      justClippedPlane = clippedPlane;
      justClippedSphere = clippedSphere;

      t += tstep;
      if (t > tfar)
      {
        break;
      }
      pos += step;
      continue;
    }

    float3 texCoord = calcTexCoord(pos, volSizeHalf);

    const float sample = volume<bpc>(texCoord);

    // Post-classification transfer-function lookup.
    float4 src;

    if (mipMode == 0)
    {
      src = tex1D(tfTexture, sample);
    }
    else if ((mipMode == 1) && (sample > maxIntensity))
    {
      dst = tex1D(tfTexture, sample);
      maxIntensity = sample;
    }
    else if ((mipMode == 2) && (sample  < minIntensity))
    {
      dst = tex1D(tfTexture, sample);
      minIntensity = sample;
    }

    // Local illumination.
    if (lighting && (src.w > 0.1))
    {
      const float3 Ka = make_float3(0.0f, 0.0f, 0.0f);
      const float3 Kd = make_float3(0.8f, 0.8f, 0.8f);
      const float3 Ks = make_float3(0.8f, 0.8f, 0.8f);
      const float shininess = 1000.0f;
      if (justClippedPlane)
      {
        src = blinnPhong<bpc>(src, texCoord, L, H, Ka, Kd, Ks, shininess, &planeNormal);
        justClippedPlane = false;
      }
      else if (justClippedSphere)
      {
        float3 sphereNormal = normalize(pos - sphereCenter);
        src = blinnPhong<bpc>(src, texCoord, L, H, Ka, Kd, Ks, shininess, &sphereNormal);
        justClippedSphere = false;
      }
      else
      {
        src = blinnPhong<bpc>(src, texCoord, L, H, Ka, Kd, Ks, shininess);
      }
    }
    justClippedPlane = false;
    justClippedSphere = false;

    if (opacityCorrection)
    {
      src.w = 1 - powf(1 - src.w, dist);
    }

    // pre-multiply alpha
    src.x *= src.w;
    src.y *= src.w;
    src.z *= src.w;

    if (frontToBack && (mipMode == 0))
    {
      dst = dst + src * (1.0f - dst.w);
    }
    else if (!frontToBack && (mipMode == 0))
    {
      //dst = dst * src.w + src * (1.0f - src.w);
    }

    if (earlyRayTermination && (dst.w > opacityThreshold))
    {
      break;
    }

    t += tstep;
    if (t > tfar)
    {
      break;
    }

    pos += step;
  }
  d_output[y * width + x] = rgbaFloatToInt(dst);
}

vvRayRend::vvRayRend(vvVolDesc* vd, vvRenderState renderState)
  : vvRenderer(vd, renderState)
{
  glewInit();
  cudaGLSetGLDevice(0);

  _earlyRayTermination = true;
  _illumination = false;
  _interpolation = true;
  _opacityCorrection = true;

  _pbo = NULL;
  _gltex = NULL;

  initPbo(512, 512);

  d_randArray = 0;
  initRandTexture();

  d_volumeArray = 0;
  initVolumeTexture();

  d_transferFuncArray = 0;
  updateTransferFunction();
}

vvRayRend::~vvRayRend()
{
  cudaFreeArray(d_volumeArray);
  cudaFreeArray(d_transferFuncArray);
  cudaFreeArray(d_randArray);
}

int vvRayRend::getLUTSize() const
{
   vvDebugMsg::msg(2, "vvSoftVR::getLUTSize()");
   return (vd->getBPV()==2) ? 4096 : 256;
}

void vvRayRend::updateTransferFunction()
{
  int lutEntries = getLUTSize();
  float* rgba = new float[4 * lutEntries];

  vd->computeTFTexture(lutEntries, 1, 1, rgba);

  cudaChannelFormatDesc channelDesc = cudaCreateChannelDesc<float4>();

  cudaFreeArray(d_transferFuncArray);
  cudaMallocArray(&d_transferFuncArray, &channelDesc, lutEntries, 1);
  cudaMemcpyToArray(d_transferFuncArray, 0, 0, rgba, lutEntries * 4 * sizeof(float), cudaMemcpyHostToDevice);


  tfTexture.filterMode = cudaFilterModeLinear;
  tfTexture.normalized = true;    // access with normalized texture coordinates
  tfTexture.addressMode[0] = cudaAddressModeClamp;   // wrap texture coordinates

  cudaBindTextureToArray(tfTexture, d_transferFuncArray, channelDesc);

  delete[] rgba;
}

void vvRayRend::resize(const int width, const int height)
{
  initPbo(width, height);
  renderVolumeGL();
}

void vvRayRend::renderVolumeGL()
{
  vvDebugMsg::msg(1, "vvRayRend::renderVolumeGL()");

  const vvGLTools::Viewport vp = vvGLTools::getViewport();
  const int width = vp[2];
  const int height = vp[3];

  uint* d_output = 0;
  // map PBO to get CUDA device pointer
  cudaGLMapBufferObject((void**)&d_output, _pbo);

  dim3 blockSize(16, 16);
  dim3 gridSize = dim3(iDivUp(width, blockSize.x), iDivUp(height, blockSize.y));

  const vvVector3 size(vd->getSize());
  const vvVector3 size2 = size * 0.5f;

  // Assume: no probe.
  vvVector3 probeSizeObj;
  probeSizeObj.copy(&size);
  vvVector3 probeMin;
  probeMin = -size2;
  vvVector3 probeMax;
  probeMax = size2;

  vvVector3 clippedProbeSizeObj;
  clippedProbeSizeObj.copy(&probeSizeObj);
  for (int i=0; i<3; ++i)
  {
    if (clippedProbeSizeObj[i] < vd->getSize()[i])
    {
      clippedProbeSizeObj[i] = vd->getSize()[i];
    }
  }

  const float diagonal = sqrtf(clippedProbeSizeObj[0] * clippedProbeSizeObj[0] +
                               clippedProbeSizeObj[1] * clippedProbeSizeObj[1] +
                               clippedProbeSizeObj[2] * clippedProbeSizeObj[2]);

  const float diagonalVoxels = sqrtf(float(vd->vox[0] * vd->vox[0] +
                                           vd->vox[1] * vd->vox[1] +
                                           vd->vox[2] * vd->vox[2]));
  int numSlices = max(1, static_cast<int>(_renderState._quality * diagonalVoxels));

  // Inverse modelview-projection matrix.
  vvMatrix mvp, pr;
  getModelviewMatrix(&mvp);

  // Not related.
  vvMatrix invMV;
  invMV.copy(&mvp);
  invMV.invert();
  // Not related.

  getProjectionMatrix(&pr);
  mvp.multiplyPost(&pr);
  mvp.invert();

  float* viewM = new float[16];
  mvp.get(viewM);
  cudaMemcpyToSymbol(c_invViewMatrix, viewM, sizeof(float4) * 4);
  delete[] viewM;

  float3 volSize = make_float3(vd->vox[0], vd->vox[1], vd->vox[2]);

  bool isOrtho = pr.isProjOrtho();

  vvVector3 eye;
  getEyePosition(&eye);
  eye.multiply(&invMV);

  vvVector3 origin;

  vvVector3 normal;
  getObjNormal(normal, origin, eye, invMV, isOrtho);

  const float3 N = make_float3(normal[0], normal[1], normal[2]);

  const float3 L(-N);

  // Viewing direction.
  const float3 V(-N);

  // Half way vector.
  const float3 H = normalize(L + V);

  // Clip sphere.
  const float3 center = make_float3(_renderState._roiPos[0],
                                    _renderState._roiPos[1],
                                    _renderState._roiPos[2]);//make_float3(0.0f, 128.0f, 128.0f);
  const float radius = _renderState._roiSize[0] * vd->getSize()[0];//150;

  // Clip plane.
  const float3 pnormal = normalize(make_float3(0.0f, 0.71f, 0.63f));
  const float pdist = 0.0f;

  if (vd->bpc == 1)
  {
    if (_illumination && _earlyRayTermination && _opacityCorrection)
    {
      render<
             true, // Early ray termination.
             true, // Front to back.
             1, // Bytes per channel.
             0, // Mip mode.
             true, // Local illumination.
             true, // Opacity correction.
             false, // Jittering.
             false, // Clip sphere.
             false, // Clip plane.
             false // Show what's inside the clip sphere.
            ><<<gridSize, blockSize>>>(d_output, width, height,
                                       diagonalVoxels / (float)numSlices,
                                       volSize * 0.5f,
                                       L, H,
                                       center, radius * radius,
                                       pnormal, pdist);
    }
    else if (!_illumination && _earlyRayTermination && _opacityCorrection)
    {
      render<
             true, // Early ray termination.
             true, // Front to back.
             1, // Bytes per channel.
             0, // Mip mode.
             false, // Local illumination.
             true, // Opacity correction.
             false, // Jittering.
             false, // Clip sphere.
             false, // Clip plane.
             false // Show what's inside the clip sphere.
            ><<<gridSize, blockSize>>>(d_output, width, height,
                                       diagonalVoxels / (float)numSlices,
                                       volSize * 0.5f,
                                       L, H,
                                       center, radius * radius,
                                       pnormal, pdist);
    }
    else if (_illumination && !_earlyRayTermination && _opacityCorrection)
    {
      render<
             false, // Early ray termination.
             true, // Front to back.
             1, // Bytes per channel.
             0, // Mip mode.
             true, // Local illumination.
             true, // Opacity correction.
             false, // Jittering.
             false, // Clip sphere.
             false, // Clip plane.
             false // Show what's inside the clip sphere.
            ><<<gridSize, blockSize>>>(d_output, width, height,
                                       diagonalVoxels / (float)numSlices,
                                       volSize * 0.5f,
                                       L, H,
                                       center, radius * radius,
                                       pnormal, pdist);
    }
    else if (_illumination && _earlyRayTermination && !_opacityCorrection)
    {
      render<
             true, // Early ray termination.
             true, // Front to back.
             1, // Bytes per channel.
             0, // Mip mode.
             true, // Local illumination.
             false, // Opacity correction.
             false, // Jittering.
             false, // Clip sphere.
             false, // Clip plane.
             false // Show what's inside the clip sphere.
            ><<<gridSize, blockSize>>>(d_output, width, height,
                                       diagonalVoxels / (float)numSlices,
                                       volSize * 0.5f,
                                       L, H,
                                       center, radius * radius,
                                       pnormal, pdist);
    }
    else if (!_illumination && !_earlyRayTermination && _opacityCorrection)
    {
      render<
             false, // Early ray termination.
             true, // Front to back.
             1, // Bytes per channel.
             0, // Mip mode.
             false, // Local illumination.
             true, // Opacity correction.
             false, // Jittering.
             false, // Clip sphere.
             false, // Clip plane.
             false // Show what's inside the clip sphere.
            ><<<gridSize, blockSize>>>(d_output, width, height,
                                       diagonalVoxels / (float)numSlices,
                                       volSize * 0.5f,
                                       L, H,
                                       center, radius * radius,
                                       pnormal, pdist);
    }
    else if (_illumination && !_earlyRayTermination && !_opacityCorrection)
    {
      render<
             false, // Early ray termination.
             true, // Front to back.
             1, // Bytes per channel.
             0, // Mip mode.
             true, // Local illumination.
             false, // Opacity correction.
             false, // Jittering.
             false, // Clip sphere.
             false, // Clip plane.
             false // Show what's inside the clip sphere.
            ><<<gridSize, blockSize>>>(d_output, width, height,
                                       diagonalVoxels / (float)numSlices,
                                       volSize * 0.5f,
                                       L, H,
                                       center, radius * radius,
                                       pnormal, pdist);
    }
    else if (!_illumination && _earlyRayTermination && !_opacityCorrection)
    {
      render<
             true, // Early ray termination.
             true, // Front to back.
             1, // Bytes per channel.
             0, // Mip mode.
             false, // Local illumination.
             false, // Opacity correction.
             false, // Jittering.
             false, // Clip sphere.
             false, // Clip plane.
             false // Show what's inside the clip sphere.
            ><<<gridSize, blockSize>>>(d_output, width, height,
                                       diagonalVoxels / (float)numSlices,
                                       volSize * 0.5f,
                                       L, H,
                                       center, radius * radius,
                                       pnormal, pdist);
    }
    else if (!_illumination && !_earlyRayTermination && !_opacityCorrection)
    {
      render<
             false, // Early ray termination.
             true, // Front to back.
             1, // Bytes per channel.
             0, // Mip mode.
             false, // Local illumination.
             false, // Opacity correction.
             false, // Jittering.
             false, // Clip sphere.
             false, // Clip plane.
             false // Show what's inside the clip sphere.
            ><<<gridSize, blockSize>>>(d_output, width, height,
                                       diagonalVoxels / (float)numSlices,
                                       volSize * 0.5f,
                                       L, H,
                                       center, radius * radius,
                                       pnormal, pdist);
    }
  }
  else if (vd->bpc == 2)
  {
    if (_illumination && _earlyRayTermination && _opacityCorrection)
    {
      render<
             true, // Early ray termination.
             true, // Front to back.
             2, // Bytes per channel.
             0, // Mip mode.
             true, // Local illumination.
             true, // Opacity correction.
             false, // Jittering.
             false, // Clip sphere.
             false, // Clip plane.
             false // Show what's inside the clip sphere.
            ><<<gridSize, blockSize>>>(d_output, width, height,
                                       diagonalVoxels / (float)numSlices,
                                       volSize * 0.5f,
                                       L, H,
                                       center, radius * radius,
                                       pnormal, pdist);
    }
    else if (!_illumination && _earlyRayTermination && _opacityCorrection)
    {
      render<
             true, // Early ray termination.
             true, // Front to back.
             2, // Bytes per channel.
             0, // Mip mode.
             false, // Local illumination.
             true, // Opacity correction.
             false, // Jittering.
             false, // Clip sphere.
             false, // Clip plane.
             false // Show what's inside the clip sphere.
            ><<<gridSize, blockSize>>>(d_output, width, height,
                                       diagonalVoxels / (float)numSlices,
                                       volSize * 0.5f,
                                       L, H,
                                       center, radius * radius,
                                       pnormal, pdist);
    }
    else if (_illumination && !_earlyRayTermination && _opacityCorrection)
    {
      render<
             false, // Early ray termination.
             true, // Front to back.
             2, // Bytes per channel.
             0, // Mip mode.
             true, // Local illumination.
             true, // Opacity correction.
             false, // Jittering.
             false, // Clip sphere.
             false, // Clip plane.
             false // Show what's inside the clip sphere.
            ><<<gridSize, blockSize>>>(d_output, width, height,
                                       diagonalVoxels / (float)numSlices,
                                       volSize * 0.5f,
                                       L, H,
                                       center, radius * radius,
                                       pnormal, pdist);
    }
    else if (_illumination && _earlyRayTermination && !_opacityCorrection)
    {
      render<
             true, // Early ray termination.
             true, // Front to back.
             2, // Bytes per channel.
             0, // Mip mode.
             true, // Local illumination.
             false, // Opacity correction.
             false, // Jittering.
             false, // Clip sphere.
             false, // Clip plane.
             false // Show what's inside the clip sphere.
            ><<<gridSize, blockSize>>>(d_output, width, height,
                                       diagonalVoxels / (float)numSlices,
                                       volSize * 0.5f,
                                       L, H,
                                       center, radius * radius,
                                       pnormal, pdist);
    }
    else if (!_illumination && !_earlyRayTermination && _opacityCorrection)
    {
      render<
             false, // Early ray termination.
             true, // Front to back.
             2, // Bytes per channel.
             0, // Mip mode.
             false, // Local illumination.
             true, // Opacity correction.
             false, // Jittering.
             false, // Clip sphere.
             false, // Clip plane.
             false // Show what's inside the clip sphere.
            ><<<gridSize, blockSize>>>(d_output, width, height,
                                       diagonalVoxels / (float)numSlices,
                                       volSize * 0.5f,
                                       L, H,
                                       center, radius * radius,
                                       pnormal, pdist);
    }
    else if (_illumination && !_earlyRayTermination && !_opacityCorrection)
    {
      render<
             false, // Early ray termination.
             true, // Front to back.
             2, // Bytes per channel.
             0, // Mip mode.
             true, // Local illumination.
             false, // Opacity correction.
             false, // Jittering.
             false, // Clip sphere.
             false, // Clip plane.
             false // Show what's inside the clip sphere.
            ><<<gridSize, blockSize>>>(d_output, width, height,
                                       diagonalVoxels / (float)numSlices,
                                       volSize * 0.5f,
                                       L, H,
                                       center, radius * radius,
                                       pnormal, pdist);
    }
    else if (!_illumination && _earlyRayTermination && !_opacityCorrection)
    {
      render<
             true, // Early ray termination.
             true, // Front to back.
             2, // Bytes per channel.
             0, // Mip mode.
             false, // Local illumination.
             false, // Opacity correction.
             false, // Jittering.
             false, // Clip sphere.
             false, // Clip plane.
             false // Show what's inside the clip sphere.
            ><<<gridSize, blockSize>>>(d_output, width, height,
                                       diagonalVoxels / (float)numSlices,
                                       volSize * 0.5f,
                                       L, H,
                                       center, radius * radius,
                                       pnormal, pdist);
    }
    else if (!_illumination && !_earlyRayTermination && !_opacityCorrection)
    {
      render<
             false, // Early ray termination.
             true, // Front to back.
             2, // Bytes per channel.
             0, // Mip mode.
             false, // Local illumination.
             false, // Opacity correction.
             false, // Jittering.
             false, // Clip sphere.
             false, // Clip plane.
             false // Show what's inside the clip sphere.
            ><<<gridSize, blockSize>>>(d_output, width, height,
                                       diagonalVoxels / (float)numSlices,
                                       volSize * 0.5f,
                                       L, H,
                                       center, radius * radius,
                                       pnormal, pdist);
    }
  }
  cudaGLUnmapBufferObject(_pbo);

  glBindBuffer(GL_PIXEL_UNPACK_BUFFER_ARB, _pbo);
  glBindTexture(GL_TEXTURE_2D, _gltex);
  glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
  glBindBuffer(GL_PIXEL_UNPACK_BUFFER_ARB, 0);

  renderQuad(width, height);
}

//----------------------------------------------------------------------------
// see parent
void vvRayRend::setParameter(const ParameterType param, const float newValue, char*)
{
  vvDebugMsg::msg(3, "vvTexRend::setParameter()");

  switch (param)
  {
  case vvRenderer::VV_SLICEINT:
    {
      const bool newInterpol = static_cast<bool>(newValue);
      if (_interpolation != newInterpol)
      {
        _interpolation = newInterpol;
        initVolumeTexture();
        updateTransferFunction();
      }
    }
    break;
  case vvRenderer::VV_LIGHTING:
    _illumination = static_cast<bool>(newValue);
    break;
  case vvRenderer::VV_OPCORR:
    _opacityCorrection = static_cast<bool>(newValue);
    break;
  default:
    vvRenderer::setParameter(param, newValue);
    break;
  }
}

void vvRayRend::initPbo(const int width, const int height)
{
  const int bitsPerPixel = 4;
  const int pboSize = width * height * bitsPerPixel;
  const int bufferSize = sizeof(GLubyte) * pboSize;
  GLubyte* pboSrc = new GLubyte[pboSize];
  glGenBuffers(1, &_pbo);
  glBindBuffer(GL_ARRAY_BUFFER, _pbo);
  glBufferData(GL_ARRAY_BUFFER, bufferSize, pboSrc, GL_DYNAMIC_DRAW);
  delete[] pboSrc;
  glBindBuffer(GL_ARRAY_BUFFER, 0);
  cudaGLRegisterBufferObject(_pbo);

  glGenTextures(1, &_gltex);
  glBindTexture(GL_TEXTURE_2D, _gltex);

  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);

  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA,
               GL_UNSIGNED_BYTE, NULL);
}

void vvRayRend::initRandTexture()
{
  const float scale = 2.0f;

  //srand(time(NULL));

  float4* randVecs = new float4[NUM_RAND_VECS];
  for (int i=0; i<NUM_RAND_VECS; ++i)
  {
    randVecs[i].x = (static_cast<float>(rand()) / static_cast<float>(INT_MAX)) * scale;
    randVecs[i].y = (static_cast<float>(rand()) / static_cast<float>(INT_MAX)) * scale;
    randVecs[i].z = (static_cast<float>(rand()) / static_cast<float>(INT_MAX)) * scale;
  }

  cudaChannelFormatDesc channelDesc = cudaCreateChannelDesc<float4>();

  cudaFreeArray(d_randArray);
  cudaMallocArray(&d_randArray, &channelDesc, NUM_RAND_VECS, 1);
  cudaMemcpyToArray(d_randArray, 0, 0, randVecs, NUM_RAND_VECS * sizeof(float4), cudaMemcpyHostToDevice);

  randTexture.filterMode = cudaFilterModeLinear;
  randTexture.addressMode[0] = cudaAddressModeClamp;

  cudaBindTextureToArray(randTexture, d_randArray, channelDesc);

  delete[] randVecs;
}

void vvRayRend::initVolumeTexture()
{
  cudaExtent volumeSize = make_cudaExtent(vd->vox[0], vd->vox[1], vd->vox[2]);

  cudaChannelFormatDesc channelDesc;
  if (vd->bpc == 1)
  {
    channelDesc = cudaCreateChannelDesc<uchar>();
  }
  else if (vd->bpc == 2)
  {
    channelDesc = cudaCreateChannelDesc<ushort>();
  }
  cudaMalloc3DArray(&d_volumeArray, &channelDesc, volumeSize);

  cudaMemcpy3DParms copyParams = { 0 };

  if (vd->bpc == 1)
  {
    copyParams.srcPtr = make_cudaPitchedPtr(vd->getRaw(0), volumeSize.width*vd->bpc, volumeSize.width, volumeSize.height);
  }
  else if (vd->bpc == 2)
  {
    const int size = vd->vox[0] * vd->vox[1] * vd->vox[2] * vd->bpc;
    uchar* raw = vd->getRaw(0);
    uchar* data = new uchar[size];

    for (int i=0; i<size; i+=2)
    {
      int val = ((int) raw[i] << 8) | (int) raw[i + 1];
      val >>= 4;
      data[i] = raw[i];
      data[i + 1] = val;
    }
    copyParams.srcPtr = make_cudaPitchedPtr(data, volumeSize.width*vd->bpc, volumeSize.width, volumeSize.height);
  }
  copyParams.dstArray = d_volumeArray;
  copyParams.extent = volumeSize;
  copyParams.kind = cudaMemcpyHostToDevice;
  cudaMemcpy3D(&copyParams);

  if (vd->bpc == 1)
  {
      volTexture8.normalized = true;
      if (_interpolation)
      {
        volTexture8.filterMode = cudaFilterModeLinear;
      }
      else
      {
        volTexture8.filterMode = cudaFilterModePoint;
      }
      volTexture8.addressMode[0] = cudaAddressModeClamp;
      volTexture8.addressMode[1] = cudaAddressModeClamp;
      cudaBindTextureToArray(volTexture8, d_volumeArray, channelDesc);
  }
  else if (vd->bpc == 2)
  {
      volTexture16.normalized = true;
      if (_interpolation)
      {
        volTexture16.filterMode = cudaFilterModeLinear;
      }
      else
      {
        volTexture16.filterMode = cudaFilterModePoint;
      }
      volTexture16.addressMode[0] = cudaAddressModeClamp;
      volTexture16.addressMode[1] = cudaAddressModeClamp;
      cudaBindTextureToArray(volTexture16, d_volumeArray, channelDesc);
  }
}

void vvRayRend::renderQuad(const int width, const int height) const
{
  glDisable(GL_DEPTH_TEST);
  glDisable(GL_LIGHTING);
  glEnable(GL_TEXTURE_2D);
  glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);

  glMatrixMode(GL_PROJECTION);
  glPushMatrix();
  glLoadIdentity();
  glOrtho(-1.0, 1.0, -1.0, 1.0, -1.0, 1.0);

  glMatrixMode( GL_MODELVIEW);
  glLoadIdentity();

  glViewport(0, 0, width, height);

  glClear(GL_COLOR_BUFFER_BIT);
  glBegin(GL_QUADS);
    glTexCoord2f(0.0, 0.0); glVertex3f(-1.0, -1.0, 0.0);
    glTexCoord2f(1.0, 0.0); glVertex3f(1.0, -1.0, 0.0);
    glTexCoord2f(1.0, 1.0); glVertex3f(1.0, 1.0, 0.0);
    glTexCoord2f(0.0, 1.0); glVertex3f(-1.0, 1.0, 0.0);
  glEnd();

  glMatrixMode(GL_PROJECTION);
  glPopMatrix();

  glDisable(GL_TEXTURE_2D);
}

#endif
