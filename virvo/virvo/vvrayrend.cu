//
// This software contains source code provided by NVIDIA Corporation.
//

#ifdef HAVE_CONFIG_H
#include "vvconfig.h"
#endif

#if defined(HAVE_CUDA) && defined(NV_PROPRIETARY_CODE)

#include "vvglew.h"

#include "vvcuda.h"
#include "vvcudaimg.h"
#include "vvcudautils.h"
#include "vvdebugmsg.h"
#include "vvgltools.h"
#include "vvrayrend.h"

#include <cuda_gl_interop.h>
#include <ctime>
#include <iostream>
#include <limits>

using std::cerr;
using std::endl;

texture<uchar, 3, cudaReadModeNormalizedFloat> volTexture8;
texture<ushort, 3, cudaReadModeNormalizedFloat> volTexture16;
texture<float4, 1, cudaReadModeElementType> tfTexture;
texture<float, 3, cudaReadModeElementType> spaceSkippingTexture;
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
__constant__ matrix4x4 c_MvPrMatrix;

struct Ray
{
  float3 o;
  float3 d;
};

template<int t_bpc>
__device__ float volume(const float x, const float y, const float z)
{
  if (t_bpc == 1)
  {
    return tex3D(volTexture8, x, y, z);
  }
  else if (t_bpc == 2)
  {
    return tex3D(volTexture16, x, y, z);
  }
  else
  {
    return -1.0f;
  }
}

template<int t_bpc>
__device__ float volume(const float3& pos)
{
  if (t_bpc == 1)
  {
    return tex3D(volTexture8, pos.x, pos.y, pos.z);
  }
  else if (t_bpc == 2)
  {
    return tex3D(volTexture16, pos.x, pos.y, pos.z);
  }
  else
  {
    return -1.0f;
  }
}

__device__ bool skipSpace(const float3& pos)
{
  //return (tex3D(spaceSkippingTexture, pos.x, pos.y, pos.z) == 0.0f);
  return false;
}

__device__ float3 calcTexCoord(const float3& pos, const float3& volPos, const float3& volSizeHalf)
{
  return make_float3((pos.x - volPos.x + volSizeHalf.x) / (volSizeHalf.x * 2.0f),
                     (pos.y - volPos.y + volSizeHalf.y) / (volSizeHalf.y * 2.0f),
                     (pos.z - volPos.z + volSizeHalf.z) / (volSizeHalf.z * 2.0f));
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


__device__ float4 mulPost(const matrix4x4& M, const float4& v)
{
  float4 result;
  result.x = M.m[0][0] * v.x + M.m[0][1] * v.y + M.m[0][2] * v.z + M.m[0][3] * v.w;
  result.y = M.m[1][0] * v.x + M.m[1][1] * v.y + M.m[1][2] * v.z + M.m[1][3] * v.w;
  result.z = M.m[2][0] * v.x + M.m[2][1] * v.y + M.m[2][2] * v.z + M.m[2][3] * v.w;
  result.w = M.m[3][0] * v.x + M.m[3][1] * v.y + M.m[3][2] * v.z + M.m[3][3] * v.w;
  return result;
}

__device__ float4 mulPre(const matrix4x4& M, const float4& v)
{
  float4 result;
  result.x = M.m[0][0] * v.x + M.m[1][0] * v.y + M.m[2][0] * v.z + M.m[3][0] * v.w;
  result.y = M.m[0][1] * v.x + M.m[1][1] * v.y + M.m[2][1] * v.z + M.m[3][1] * v.w;
  result.z = M.m[0][2] * v.x + M.m[1][2] * v.y + M.m[2][2] * v.z + M.m[3][2] * v.w;
  result.w = M.m[0][3] * v.x + M.m[1][3] * v.y + M.m[2][3] * v.z + M.m[3][3] * v.w;
  return result;
}

__device__ float3 perspectiveDivide(const float4& v)
{
  const float wInv = 1.0f / v.w;
  return make_float3(v.x * wInv, v.y * wInv, v.z * wInv);
}

__device__ uchar4 rgbaFloatToInt(float4 rgba)
{
  clamp(rgba.x);
  clamp(rgba.y);
  clamp(rgba.z);
  clamp(rgba.w);
  return make_uchar4(rgba.x * 255, rgba.y * 255,rgba.z * 255, rgba.w * 255);
}

template<int t_bpc>
__device__ float3 gradient(const float3& pos)
{
  const float DELTA = 0.01f;

  float3 sample1;
  float3 sample2;

  sample1.x = volume<t_bpc>(pos - make_float3(DELTA, 0.0f, 0.0f));
  sample2.x = volume<t_bpc>(pos + make_float3(DELTA, 0.0f, 0.0f));
  sample1.y = volume<t_bpc>(pos - make_float3(0.0f, DELTA, 0.0f));
  sample2.y = volume<t_bpc>(pos + make_float3(0.0f, DELTA, 0.0f));
  sample1.z = volume<t_bpc>(pos - make_float3(0.0f, 0.0f, DELTA));
  sample2.z = volume<t_bpc>(pos + make_float3(0.0f, 0.0f, DELTA));

  return sample2 - sample1;
}

template<int t_bpc>
__device__ float4 blinnPhong(const float4& classification, const float3& pos,
                             const float3& L, const float3& H,
                             const float3& Ka, const float3& Kd, const float3& Ks,
                             const float shininess,
                             const float3* normal = NULL)
{
  float3 N = normalize(gradient<t_bpc>(pos));

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
         bool t_earlyRayTermination,
         bool t_spaceSkipping,
         bool t_frontToBack,
         int t_bpc,
         int t_mipMode,
         bool t_lighting,
         bool t_opacityCorrection,
         bool t_jittering,
         bool t_clipPlane,
         bool t_clipSphere,
         bool t_useSphereAsProbe
        >
__global__ void render(uchar4* d_output, const uint width, const uint height,
                       const float4 backgroundColor,
                       const uint texwidth, const float dist,
                       const float3 volPos, const float3 volSizeHalf,
                       const float3 probePos, const float3 probeSizeHalf,
                       const float3 L, const float3 H,
                       const float3 sphereCenter, const float sphereRadius,
                       const float3 planeNormal, const float planeDist,
                       void* d_depth, vvImage2_5d::DepthPrecision dp)
{
  const bool t_isaDepth = true;
  const int maxSteps = INT_MAX;
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
  const float4 o = mulPost(c_invViewMatrix, make_float4(u, v, -1.0f, 1.0f));
  const float4 d = mulPost(c_invViewMatrix, make_float4(u, v, 1.0f, 1.0f));

  Ray ray;
  ray.o = perspectiveDivide(o);
  ray.d = perspectiveDivide(d);
  ray.d = ray.d - ray.o;
  ray.d = normalize(ray.d);

  float tnear;
  float tfar;
  const bool hit = intersectBox(ray, probePos - probeSizeHalf, probePos + probeSizeHalf, &tnear, &tfar);
  if (!hit)
  {
    d_output[y * texwidth + x] = make_uchar4(0);
    if(t_isaDepth)
    {
      switch(dp)
      {
      case vvImage2_5d::VV_UCHAR:
        ((unsigned char*)(d_depth))[y * texwidth + x] = 0;
        break;
      case vvImage2_5d::VV_USHORT:
        ((unsigned short*)(d_depth))[y * texwidth + x] = 0;
        break;
      case vvImage2_5d::VV_UINT:
        ((unsigned int*)(d_depth))[y * texwidth + x] = 0;
        break;
      }
    }
    return;
  }

  if (fmodf(tnear, dist) != 0.0f)
  {
    int tmp = (tnear / dist);
    tnear = dist * tmp;
  }

  if (tnear < 0.0f)
  {
    tnear = 0.0f;
  }

  // Calc hits with clip sphere.
  float tsnear;
  float tsfar;
  if (t_clipSphere)
  {
    // In probe mode, rays that don't hit the sphere simply aren't rendered.
    // In ordinary sphere mode, the intersection data is memorized.
    if (!intersectSphere(ray, sphereCenter, sphereRadius, &tsnear, &tsfar) && t_useSphereAsProbe)
    {
      d_output[y * texwidth + x] = make_uchar4(0);
      return;
    }
  }

  // Calc hits with clip plane.
  float tpnear;
  float nddot;
  if (t_clipPlane)
  {
    intersectPlane(ray, planeNormal, planeDist, &nddot, &tpnear);
  }

  float4 dst;

  if (t_mipMode > 0)
  {
    dst = backgroundColor;
  }
  else
  {
    dst = make_float4(0.0f);
  }

  float t = tnear;
  float3 pos = ray.o + ray.d * tnear;

  if (t_jittering)
  {
    const float4 randOffset = tex1D(randTexture, (y * width + x) % NUM_RAND_VECS);
    pos += make_float3(randOffset);
  }
  const float3 step = ray.d * dist;

  // If just clipped, shade with the normal of the clipping surface.
  bool justClippedPlane = false;
  bool justClippedSphere = false;

  float maxDiff = 0.;
  float3 maxDiffDepth = make_float3(0., 0., 0.);
  float lastAlpha = 0.;
  for (int i=0; i<maxSteps; ++i)
  {
    // Test for clipping.
    const bool clippedPlane = (t_clipPlane && (((t <= tpnear) && (nddot >= 0.0f))
                                            || ((t >= tpnear) && (nddot < 0.0f))));
    const bool clippedSphere = t_useSphereAsProbe ? (t_clipSphere && ((t < tsnear) || (t > tsfar)))
                                                  : (t_clipSphere && (t >= tsnear) && (t <= tsfar));

    if (clippedPlane || clippedSphere)
    {
      justClippedPlane = clippedPlane;
      justClippedSphere = clippedSphere;

      t += dist;
      if (t > tfar)
      {
        break;
      }
      pos += step;
      continue;
    }

    const float3 texCoord = calcTexCoord(pos, volPos, volSizeHalf);

    // Skip over homogeneous space.
    if (t_spaceSkipping)
    {
      if (skipSpace(texCoord))
      {
        t += dist;
        if (t > tfar)
        {
          break;
        }
        pos += step;
        continue;
      }
    }

    const float sample = volume<t_bpc>(texCoord);

    // Post-classification transfer-function lookup.
    float4 src = tex1D(tfTexture, sample);

    if (t_mipMode == 1)
    {
      dst.x = fmaxf(src.x, dst.x);
      dst.y = fmaxf(src.y, dst.y);
      dst.z = fmaxf(src.z, dst.z);
      dst.w = 1;
    }
    else if (t_mipMode == 2)
    {
      dst.x = fminf(src.x, dst.x);
      dst.y = fminf(src.y, dst.y);
      dst.z = fminf(src.z, dst.z);
      dst.w = 1;
    }

    // Local illumination.
    if (t_lighting && (src.w > 0.1f))
    {
      const float3 Ka = make_float3(0.0f, 0.0f, 0.0f);
      const float3 Kd = make_float3(0.8f, 0.8f, 0.8f);
      const float3 Ks = make_float3(0.8f, 0.8f, 0.8f);
      const float shininess = 1000.0f;
      if (justClippedPlane)
      {
        src = blinnPhong<t_bpc>(src, texCoord, L, H, Ka, Kd, Ks, shininess, &planeNormal);
        justClippedPlane = false;
      }
      else if (justClippedSphere)
      {
        float3 sphereNormal = normalize(pos - sphereCenter);
        src = blinnPhong<t_bpc>(src, texCoord, L, H, Ka, Kd, Ks, shininess, &sphereNormal);
        justClippedSphere = false;
      }
      else
      {
        src = blinnPhong<t_bpc>(src, texCoord, L, H, Ka, Kd, Ks, shininess);
      }
    }
    justClippedPlane = false;
    justClippedSphere = false;

    if (t_opacityCorrection)
    {
      src.w = 1 - powf(1 - src.w, dist);
    }

    if (t_mipMode == 0)
    {
      // pre-multiply alpha
      src.x *= src.w;
      src.y *= src.w;
      src.z *= src.w;
    }

    if (t_frontToBack && (t_mipMode == 0))
    {
      dst = dst + src * (1.0f - dst.w);
    }
    else if (!t_frontToBack && (t_mipMode == 0))
    {
      //dst = dst * src.w + src * (1.0f - src.w);
    }

    if (t_earlyRayTermination && (dst.w > opacityThreshold))
    {
      break;
    }

    t += dist;
    if (t > tfar)
    {
      break;
    }

    pos += step;

    if(t_isaDepth)
    {
      if(dst.w - lastAlpha > maxDiff)
      {
        maxDiff = dst.w - lastAlpha;
        maxDiffDepth = pos;
      }
      lastAlpha = dst.w;
    }
  }
  if(t_isaDepth)
  {
    // convert position to window-coordinates
    const float4 depthWin = mulPost(c_MvPrMatrix, make_float4(maxDiffDepth.x, maxDiffDepth.y, maxDiffDepth.z, 1.0f));
    float3 depth = perspectiveDivide(depthWin);
    // map and clip on near and far-clipping planes
    depth.z++;
    depth.z = depth.z/2.;

    if(depth.z > 1.0)
      depth.z = 1.0;
    else if(depth.z < 0.0)
      depth.z = 0.0;

    switch(dp)
    {
    case vvImage2_5d::VV_UCHAR:
      ((unsigned char*)(d_depth))[y * texwidth + x] = (unsigned char)(depth.z*float(UCHAR_MAX));
      break;
    case vvImage2_5d::VV_USHORT:
      ((unsigned short*)(d_depth))[y * texwidth + x] = (unsigned short)(depth.z*float(USHRT_MAX));
      break;
    case vvImage2_5d::VV_UINT:
      default:
      ((unsigned int*)(d_depth))[y * texwidth + x] = (unsigned int)(depth.z*float(UINT_MAX));
      break;
    }
  }
  d_output[y * texwidth + x] = rgbaFloatToInt(dst);
}

typedef void(*renderKernel)(uchar4*, const uint, const uint, const float4,
                            const uint, const float, const float3, const float3,
                            const float3, const float3, const float3, const float3, const float3,
                            const float, const float3, const float, void*, vvImage2_5d::DepthPrecision);

template<
         int t_bpc,
         bool t_illumination,
         bool t_opacityCorrection,
         bool t_earlyRayTermination,
         bool t_clipPlane,
         bool t_clipSphere,
         bool t_useSphereAsProbe,
         int t_mipMode
        >
renderKernel getKernelWithMip(vvRayRend*)
{
  return &render<t_earlyRayTermination, // Early ray termination.
                 true, // Space skipping.
                 true, // Front to back.
                 t_bpc, // Bytes per channel.
                 t_mipMode, // Mip mode.
                 t_illumination, // Local illumination.
                 t_opacityCorrection, // Opacity correction.
                 false, // Jittering.
                 t_clipPlane, // Clip plane.
                 t_clipSphere, // Clip sphere.
                 t_useSphereAsProbe // Show what's inside the clip sphere.
                >;
}

#ifdef FAST_COMPILE
template<
         int t_bpc,
         bool t_illumination,
         bool t_opacityCorrection,
         bool t_earlyRayTermination,
         bool t_clipPlane,
         bool t_clipSphere,
         bool t_useSphereAsProbe,
         int t_mipMode
        >
renderKernel getKernel(vvRayRend*)
{
  return &render<t_earlyRayTermination, // Early ray termination.
                 true, // Space skipping.
                 true, // Front to back.
                 t_bpc, // Bytes per channel.
                 t_mipMode, // Mip mode.
                 t_illumination, // Local illumination.
                 t_opacityCorrection, // Opacity correction.
                 false, // Jittering.
                 t_clipPlane, // Clip plane.
                 t_clipSphere, // Clip sphere.
                 t_useSphereAsProbe // Show what's inside the clip sphere.
                >;
}
#else
template<
         int t_bpc,
         bool t_illumination,
         bool t_opacityCorrection,
         bool t_earlyRayTermination,
         bool t_clipPlane,
         bool t_clipSphere,
         bool t_useSphereAsProbe
        >
renderKernel getKernelWithSphereAsProbe(vvRayRend* rayRend)
{
  switch ((int)rayRend->getParameter(vvRenderState::VV_MIP_MODE))
  {
  case 0:
    return getKernelWithMip<
                            t_bpc,
                            t_illumination,
                            t_opacityCorrection,
                            t_earlyRayTermination,
                            t_clipPlane,
                            t_clipSphere,
                            t_useSphereAsProbe,
                            0
                           >(rayRend);
  case 1:
    // No early ray termination possible with max intensity projection.
    return getKernelWithMip<
                            t_bpc,
                            t_illumination,
                            t_opacityCorrection,
                            false,
                            t_clipPlane,
                            t_clipSphere,
                            t_useSphereAsProbe,
                            1
                           >(rayRend);
  case 2:
    // No early ray termination possible with min intensity projection.
    return getKernelWithMip<
                            t_bpc,
                            t_illumination,
                            t_opacityCorrection,
                            false,
                            t_clipPlane,
                            t_clipSphere,
                            t_useSphereAsProbe,
                            2
                           >(rayRend);
  default:
    return getKernelWithMip<
                            t_bpc,
                            t_illumination,
                            t_opacityCorrection,
                            t_earlyRayTermination,
                            t_clipPlane,
                            t_clipSphere,
                            t_useSphereAsProbe,
                            0
                           >(rayRend);
  }
}

template<
         int t_bpc,
         bool t_illumination,
         bool t_opacityCorrection,
         bool t_earlyRayTermination,
         bool t_clipPlane
        >
renderKernel getKernelWithClipPlane(vvRayRend* rayRend)
{
  if ((bool)rayRend->getParameter(vvRenderState::VV_IS_ROI_USED)
     && (bool)rayRend->getParameter(vvRenderState::VV_SPHERICAL_ROI))
  {
    return getKernelWithSphereAsProbe<
                                      t_bpc,
                                      t_illumination,
                                      t_opacityCorrection,
                                      t_earlyRayTermination,
                                      t_clipPlane,
                                      true,
                                      true
                                     >(rayRend);
  }
  else
  {
    return getKernelWithSphereAsProbe<
                                      t_bpc,
                                      t_illumination,
                                      t_opacityCorrection,
                                      t_earlyRayTermination,
                                      t_clipPlane,
                                      false,
                                      false
                                     >(rayRend);
  }
}

template<
         int t_bpc,
         bool t_illumination,
         bool t_opacityCorrection,
         bool t_earlyRayTermination
        >
renderKernel getKernelWithEarlyRayTermination(vvRayRend* rayRend)
{
  if (rayRend->getParameter(vvRenderState::VV_CLIP_MODE))
  {
    return getKernelWithClipPlane<
                                  t_bpc,
                                  t_illumination,
                                  t_opacityCorrection,
                                  t_earlyRayTermination,
                                  true
                                 >(rayRend);
  }
  else
  {
    {
      return getKernelWithClipPlane<
                                    t_bpc,
                                    t_illumination,
                                    t_opacityCorrection,
                                    t_earlyRayTermination,
                                    false
                                   >(rayRend);
    }
  }
}

template<
         int t_bpc,
         bool t_illumination,
         bool t_opacityCorrection
        >
renderKernel getKernelWithOpacityCorrection(vvRayRend* rayRend)
{
  if (rayRend->getEarlyRayTermination())
  {
    return getKernelWithEarlyRayTermination<
                                            t_bpc,
                                            t_illumination,
                                            t_opacityCorrection,
                                            true
                                           >(rayRend);
  }
  else
  {
    return getKernelWithEarlyRayTermination<
                                            t_bpc,
                                            t_illumination,
                                            t_opacityCorrection,
                                            false
                                           >(rayRend);
  }
}

template<
         int t_bpc,
         bool t_illumination
        >
renderKernel getKernelWithIllumination(vvRayRend* rayRend)
{
  if (rayRend->getOpacityCorrection())
  {
    return getKernelWithOpacityCorrection<t_bpc, t_illumination, true>(rayRend);
  }
  else
  {
    return getKernelWithOpacityCorrection<t_bpc, t_illumination, false>(rayRend);
  }
}

template<
         int t_bpc
        >
renderKernel getKernelWithBpc(vvRayRend* rayRend)
{
  if (rayRend->getIllumination())
  {
    return getKernelWithIllumination<t_bpc, true>(rayRend);
  }
  else
  {
    return getKernelWithIllumination<t_bpc, false>(rayRend);
  }
}

renderKernel getKernel(vvRayRend* rayRend)
{
  if (rayRend->getVolDesc()->bpc == 1)
  {
    return getKernelWithBpc<1>(rayRend);
  }
  else if (rayRend->getVolDesc()->bpc == 2)
  {
    return getKernelWithBpc<2>(rayRend);
  }
  else
  {
    return getKernelWithBpc<1>(rayRend);
  }
}
#endif

vvRayRend::vvRayRend(vvVolDesc* vd, vvRenderState renderState)
  : vvSoftVR(vd, renderState)
{
  glewInit();

  _volumeCopyToGpuOk = true;

  _earlyRayTermination = true;
  _illumination = false;
  _interpolation = true;
  _opacityCorrection = true;
  _spaceSkipping = false;
  h_spaceSkippingArray = NULL;
  h_cellMinValues = NULL;
  h_cellMaxValues = NULL;

  _rgbaTF = NULL;

#if 0
  const int numCells[] = { 16, 16, 16 };
  setNumSpaceSkippingCells(numCells);
#endif
  d_spaceSkippingArray = 0;

  intImg = new vvCudaImg(0, 0);

  const vvCudaImg::Mode mode = dynamic_cast<vvCudaImg*>(intImg)->getMode();
  if (mode == vvCudaImg::TEXTURE)
  {
    setWarpMode(CUDATEXTURE);
  }

  factorViewMatrix();
  bool ignoreMe;
  vvCuda::checkError(&ignoreMe, cudaGetLastError(), "rayRend-constructor");
  d_randArray = 0;
  initRandTexture();

  initVolumeTexture();

  d_transferFuncArray = 0;
  updateTransferFunction();
}

vvRayRend::~vvRayRend()
{
  bool ok;
  for (int f=0; f<d_volumeArrays.size(); ++f)
  {
    vvCuda::checkError(&ok, cudaFreeArray(d_volumeArrays[f]),
                       "vvRayRend::~vvRayRend() - free volume frame");
  }

  vvCuda::checkError(&ok, cudaFreeArray(d_transferFuncArray),
                     "vvRayRend::~vvRayRend() - free tf");
  vvCuda::checkError(&ok, cudaFreeArray(d_randArray),
                     "vvRayRend::~vvRayRend() - free rand array");
  vvCuda::checkError(&ok, cudaFreeArray(d_spaceSkippingArray),
                     "vvRayRend::~vvRayRend() - free space skipping array");

  delete[] h_spaceSkippingArray;
  delete[] h_cellMinValues;
  delete[] h_cellMaxValues;
  delete[] _rgbaTF;
}

int vvRayRend::getLUTSize() const
{
   vvDebugMsg::msg(2, "vvRayRend::getLUTSize()");
   return (vd->getBPV()==2) ? 4096 : 256;
}

void vvRayRend::updateTransferFunction()
{
  bool ok;

  int lutEntries = getLUTSize();
  delete[] _rgbaTF;
  _rgbaTF = new float[4 * lutEntries];

  vd->computeTFTexture(lutEntries, 1, 1, _rgbaTF);

  if (_spaceSkipping)
  {
    computeSpaceSkippingTexture();
    initSpaceSkippingTexture();
  }

  cudaChannelFormatDesc channelDesc = cudaCreateChannelDesc<float4>();

  vvCuda::checkError(&ok, cudaFreeArray(d_transferFuncArray),
                     "vvRayRend::updateTransferFunction() - free tf texture");
  vvCuda::checkError(&ok, cudaMallocArray(&d_transferFuncArray, &channelDesc, lutEntries, 1),
                     "vvRayRend::updateTransferFunction() - malloc tf texture");
  vvCuda::checkError(&ok, cudaMemcpyToArray(d_transferFuncArray, 0, 0, _rgbaTF, lutEntries * 4 * sizeof(float),
                                            cudaMemcpyHostToDevice),
                     "vvRayRend::updateTransferFunction() - copy tf texture to device");


  tfTexture.filterMode = cudaFilterModeLinear;
  tfTexture.normalized = true;    // access with normalized texture coordinates
  tfTexture.addressMode[0] = cudaAddressModeClamp;   // wrap texture coordinates

  vvCuda::checkError(&ok, cudaBindTextureToArray(tfTexture, d_transferFuncArray, channelDesc),
                     "vvRayRend::updateTransferFunction() - bind tf texture");
}

void vvRayRend::compositeVolume(int w, int h)
{
  if(!_volumeCopyToGpuOk)
  {
    std::cerr << "vvRayRend::compositeVolume() aborted because of previous CUDA-Error" << std::endl;
    return;
  }
  vvDebugMsg::msg(1, "vvRayRend::compositeVolume()");

  vvGLTools::Viewport vp = vvGLTools::getViewport();

  if ((w > 0) && (h > 0))
  {
    vp[2]=w; vp[3]=h;
    intImg->setSize(w, h);

    switch(_depthPrecision)
    {
    case vvImage2_5d::VV_UCHAR:
      cudaMalloc(&_depthUchar, w*h*sizeof(unsigned char));
      break;
    case vvImage2_5d::VV_USHORT:
      cudaMalloc(&_depthUshort, w*h*sizeof(unsigned short));
      break;
    case vvImage2_5d::VV_UINT:
      cudaMalloc(&_depthUint, w*h*sizeof(unsigned int));
      break;
    }
  }

  vp.print();

  dynamic_cast<vvCudaImg*>(intImg)->map();

  dim3 blockSize(16, 16);
  dim3 gridSize = dim3(iDivUp(vp[2], blockSize.x), iDivUp(vp[3], blockSize.y));
  const vvVector3 size(vd->getSize());

  vvVector3 probePosObj;
  vvVector3 probeSizeObj;
  vvVector3 probeMin;
  vvVector3 probeMax;
  calcProbeDims(probePosObj, probeSizeObj, probeMin, probeMax);

  vvVector3 clippedProbeSizeObj;
  clippedProbeSizeObj.copy(&probeSizeObj);
  for (int i=0; i<3; ++i)
  {
    if (clippedProbeSizeObj[i] < vd->getSize()[i])
    {
      clippedProbeSizeObj[i] = vd->getSize()[i];
    }
  }

  if (_isROIUsed && !_sphericalROI)
  {
    drawBoundingBox(&probeSizeObj, &_roiPos, &_probeColor);
  }

  const float diagonalVoxels = sqrtf(float(vd->vox[0] * vd->vox[0] +
                                           vd->vox[1] * vd->vox[1] +
                                           vd->vox[2] * vd->vox[2]));
  int numSlices = max(1, static_cast<int>(_quality * diagonalVoxels));

  vvMatrix Mv, MvPr;
  getModelviewMatrix(&Mv);
  getProjectionMatrix(&MvPr);
  MvPr.multiplyPre(&Mv);

  float* mvprM = new float[16];
  MvPr.get(mvprM);
  cudaMemcpyToSymbol(c_MvPrMatrix, mvprM, sizeof(float4) * 4);

  vvMatrix invMv;
  invMv.copy(&Mv);
  invMv.invert();

  vvMatrix pr;
  getProjectionMatrix(&pr);

  vvMatrix invMvpr;
  getModelviewMatrix(&invMvpr);
  invMvpr.multiplyPost(&pr);
  invMvpr.invert();

  float* viewM = new float[16];
  invMvpr.get(viewM);
  cudaMemcpyToSymbol(c_invViewMatrix, viewM, sizeof(float4) * 4);
  delete[] viewM;

  const float3 volPos = make_float3(vd->pos[0], vd->pos[1], vd->pos[2]);
  float3 probePos = volPos;
  if (_isROIUsed && !_sphericalROI)
  {
    probePos = make_float3(probePosObj[0],  probePosObj[1], probePosObj[2]);
  }
  vvVector3 sz = vd->getSize();
  const float3 volSize = make_float3(sz[0], sz[1], sz[2]);
  float3 probeSize = make_float3(probeSizeObj[0], probeSizeObj[1], probeSizeObj[2]);
  if (_sphericalROI)
  {
    probeSize = make_float3(vd->vox[0], vd->vox[1], vd->vox[2]);
  }

  const bool isOrtho = pr.isProjOrtho();

  vvVector3 eye;
  getEyePosition(&eye);
  eye.multiply(&invMv);

  vvVector3 origin;

  vvVector3 normal;
  getShadingNormal(normal, origin, eye, invMv, isOrtho);

  const float3 N = make_float3(normal[0], normal[1], normal[2]);

  const float3 L(-N);

  // Viewing direction.
  const float3 V(-N);

  // Half way vector.
  const float3 H = normalize(L + V);

  // Clip sphere.
  const float3 center = make_float3(_roiPos[0], _roiPos[1], _roiPos[2]);
  const float radius = _roiSize[0] * vd->getSize()[0];

  // Clip plane.
  const float3 pnormal = normalize(make_float3(_clipNormal[0], _clipNormal[1], _clipNormal[2]));
  const float pdist = _clipNormal.dot(&_clipPoint);

  if (_clipMode && _clipPerimeter)
  {
    drawPlanePerimeter(&size, &vd->pos, &_clipPoint, &_clipNormal, &_clipColor);
  }

  GLfloat bgcolor[4];
  glGetFloatv(GL_COLOR_CLEAR_VALUE, bgcolor);
  float4 backgroundColor = make_float4(bgcolor[0], bgcolor[1], bgcolor[2], bgcolor[3]);

#ifdef FAST_COMPILE
  renderKernel kernel = getKernel<
                        1,
                        true, // Local illumination.
                        true, // Opacity correction
                        true, // Early ray termination.
                        false, // Use clip plane.
                        false, // Use clip sphere.
                        false, // Use clip sphere as probe (inverted sphere).
                        0 // Mip mode.
                       >(this);
#else
  renderKernel kernel = getKernel(this);
#endif

  if (kernel != NULL)
  {
    if (vd->bpc == 1)
    {
      cudaBindTextureToArray(volTexture8, d_volumeArrays[vd->getCurrentFrame()], _channelDesc);
    }
    else if (vd->bpc == 2)
    {
      cudaBindTextureToArray(volTexture16, d_volumeArrays[vd->getCurrentFrame()], _channelDesc);
    }
    switch(_depthPrecision)
    {
    case vvImage2_5d::VV_UCHAR:
      (kernel)<<<gridSize, blockSize>>>(dynamic_cast<vvCudaImg*>(intImg)->getDImg(), vp[2], vp[3],
                                        backgroundColor, intImg->width,diagonalVoxels / (float)numSlices,
                                        volPos, volSize * 0.5f,
                                        probePos, probeSize * 0.5f,
                                        L, H,
                                        center, radius * radius,
                                        pnormal, pdist, _depthUchar, _depthPrecision);
      break;
    case vvImage2_5d::VV_USHORT:
      (kernel)<<<gridSize, blockSize>>>(dynamic_cast<vvCudaImg*>(intImg)->getDImg(), vp[2], vp[3],
                                        backgroundColor, intImg->width,diagonalVoxels / (float)numSlices,
                                        volPos, volSize * 0.5f,
                                        probePos, probeSize * 0.5f,
                                        L, H,
                                        center, radius * radius,
                                        pnormal, pdist, _depthUshort, _depthPrecision);
      break;
    case vvImage2_5d::VV_UINT:
      (kernel)<<<gridSize, blockSize>>>(dynamic_cast<vvCudaImg*>(intImg)->getDImg(), vp[2], vp[3],
                                        backgroundColor, intImg->width,diagonalVoxels / (float)numSlices,
                                        volPos, volSize * 0.5f,
                                        probePos, probeSize * 0.5f,
                                        L, H,
                                        center, radius * radius,
                                        pnormal, pdist, _depthUint, _depthPrecision);
      break;
    }
  }
  dynamic_cast<vvCudaImg*>(intImg)->unmap();

  // For bounding box, tf palette display, etc.
  vvRenderer::renderVolumeGL();
}
//----------------------------------------------------------------------------
// see parent
void vvRayRend::setParameter(const ParameterType param, const float newValue)
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

        if (_spaceSkipping)
        {
          initSpaceSkippingTexture();
        }
      }
    }
    break;
  case vvRenderer::VV_LIGHTING:
    _illumination = static_cast<bool>(newValue);
    break;
  case vvRenderer::VV_OPCORR:
    _opacityCorrection = static_cast<bool>(newValue);
    break;
  case vvRenderer::VV_TERMINATEEARLY:
    _earlyRayTermination = static_cast<bool>(newValue);
    break;
  default:
    vvRenderer::setParameter(param, newValue);
    break;
  }
}

void vvRayRend::setNumSpaceSkippingCells(const int numSpaceSkippingCells[3])
{
  for (int d=0; d<3; ++d)
  {
    h_numCells[d] = numSpaceSkippingCells[d];
  }
  calcSpaceSkippingGrid();
}

bool vvRayRend::getEarlyRayTermination() const
{
  return _earlyRayTermination;
}
bool vvRayRend::getIllumination() const
{
  return _illumination;
}

bool vvRayRend::getInterpolation() const
{
  return _interpolation;
}

bool vvRayRend::getOpacityCorrection() const
{
  return _opacityCorrection;
}

bool vvRayRend::getSpaceSkipping() const
{
  return _spaceSkipping;
}

void vvRayRend::initRandTexture()
{
  bool ok;

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

  vvCuda::checkError(&ok, cudaFreeArray(d_randArray),
                     "vvRayRend::initRandTexture()");
  vvCuda::checkError(&ok, cudaMallocArray(&d_randArray, &channelDesc, NUM_RAND_VECS, 1),
                     "vvRayRend::initRandTexture()");
  vvCuda::checkError(&ok, cudaMemcpyToArray(d_randArray, 0, 0, randVecs, NUM_RAND_VECS * sizeof(float4),
                                            cudaMemcpyHostToDevice), "vvRayRend::initRandTexture()");

  randTexture.filterMode = cudaFilterModeLinear;
  randTexture.addressMode[0] = cudaAddressModeClamp;

  vvCuda::checkError(&ok, cudaBindTextureToArray(randTexture, d_randArray, channelDesc),
                     "vvRayRend::initRandTexture()");

  delete[] randVecs;
}

void vvRayRend::initSpaceSkippingTexture()
{
  bool ok;

  cudaExtent numBricks = make_cudaExtent(h_numCells[0], h_numCells[1], h_numCells[2]);

  cudaChannelFormatDesc channelDesc = cudaCreateChannelDesc<bool>();

  vvCuda::checkError(&ok, cudaFreeArray(d_spaceSkippingArray),
                     "vvRayRend::initSpaceSkippingTexture()");
  vvCuda::checkError(&ok, cudaMalloc3DArray(&d_spaceSkippingArray, &channelDesc, numBricks),
                     "vvRayRend::initSpaceSkippingTexture()");

  cudaMemcpy3DParms copyParams = { 0 };

  copyParams.srcPtr = make_cudaPitchedPtr(h_spaceSkippingArray, numBricks.width*vd->bpc, numBricks.width, numBricks.height);
  copyParams.dstArray = d_spaceSkippingArray;
  copyParams.extent = numBricks;
  copyParams.kind = cudaMemcpyHostToDevice;
  vvCuda::checkError(&ok, cudaMemcpy3D(&copyParams), "vvRayRend::initSpaceSkippingTexture()");
}

void vvRayRend::initVolumeTexture()
{
  bool ok;

  cudaExtent volumeSize = make_cudaExtent(vd->vox[0], vd->vox[1], vd->vox[2]);
  if (vd->bpc == 1)
  {
    _channelDesc = cudaCreateChannelDesc<uchar>();
  }
  else if (vd->bpc == 2)
  {
    _channelDesc = cudaCreateChannelDesc<ushort>();
  }
  d_volumeArrays.resize(vd->frames);

  // Free "cuda error cache".
  vvCuda::checkError(&ok, cudaGetLastError(), "vvRayRend::initVolumeTexture() - free cuda error cache");

  int outOfMemFrame = -1;
  for (int f=0; f<vd->frames; ++f)
  {
    vvCuda::checkError(&_volumeCopyToGpuOk, cudaMalloc3DArray(&d_volumeArrays[f],
                                            &_channelDesc,
                                            volumeSize),
                       "vvRayRend::initVolumeTexture() - try to alloc 3D array");
    size_t availableMem;
    size_t totalMem;
    vvCuda::checkError(&ok, cudaMemGetInfo(&availableMem, &totalMem),
                       "vvRayRend::initVolumeTexture() - get mem info from device");

    if(!_volumeCopyToGpuOk)
    {
      outOfMemFrame = f;
      break;
    }

    vvDebugMsg::msg(1, "Total CUDA memory:     ", (int)totalMem);
    vvDebugMsg::msg(1, "Available CUDA memory: ", (int)availableMem);

    cudaMemcpy3DParms copyParams = { 0 };

    if (vd->bpc == 1)
    {
      copyParams.srcPtr = make_cudaPitchedPtr(vd->getRaw(f), volumeSize.width*vd->bpc, volumeSize.width, volumeSize.height);
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
    copyParams.dstArray = d_volumeArrays[f];
    copyParams.extent = volumeSize;
    copyParams.kind = cudaMemcpyHostToDevice;
    vvCuda::checkError(&ok, cudaMemcpy3D(&copyParams),
                       "vvRayRend::initVolumeTexture() - copy volume frame to 3D array");
  }

  if (outOfMemFrame >= 0)
  {
    cerr << "Couldn't accomodate the volume" << endl;
    for (int f=0; f<=outOfMemFrame; ++f)
    {
      vvCuda::checkError(&ok, cudaFree(d_volumeArrays[f]),
                         "vvRayRend::initVolumeTexture() - free memory after failure");
      d_volumeArrays[f] = NULL;
    }
  }

  if (vd->bpc == 1)
  {
    for (int f=0; f<outOfMemFrame; ++f)
    {
      vvCuda::checkError(&ok, cudaFreeArray(d_volumeArrays[f]),
                         "vvRayRend::initVolumeTexture() - why do we do this right here?");
      d_volumeArrays[f] = NULL;
    }
  }

  if (_volumeCopyToGpuOk)
  {
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
        vvCuda::checkError(&ok, cudaBindTextureToArray(volTexture8, d_volumeArrays[0], _channelDesc),
                           "vvRayRend::initVolumeTexture() - bind volume texture (bpc == 1)");
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
        vvCuda::checkError(&ok, cudaBindTextureToArray(volTexture16, d_volumeArrays[0], _channelDesc),
                           "vvRayRend::initVolumeTexture() - bind volume texture (bpc == 2)");
    }
  }
}

void vvRayRend::factorViewMatrix()
{
  vvGLTools::Viewport vp = vvGLTools::getViewport();
  const int w = vvToolshed::getTextureSize(vp[2]);
  const int h = vvToolshed::getTextureSize(vp[3]);

  if ((intImg->width != w) || (intImg->height != h))
  {
    intImg->setSize(w, h);
  }

  iwWarp.identity();
  iwWarp.translate(-1.0f, -1.0f, 0.0f);
  iwWarp.scale(1.0f / (static_cast<float>(vp[2]) * 0.5f), 1.0f / (static_cast<float>(vp[3]) * 0.5f), 0.0f);
}

void vvRayRend::findAxisRepresentations()
{
  // Overwrite default behavior.
}

void vvRayRend::calcSpaceSkippingGrid()
{
  delete[] h_cellMinValues;
  delete[] h_cellMaxValues;
  const int numCells = h_numCells[0] * h_numCells[1] * h_numCells[2];
  h_cellMinValues = new int[numCells];
  h_cellMaxValues = new int[numCells];

  // Cells are uniformly sized. If vd->size[d] isn't a multiple of cellSize[d],
  // the last cell will be larger than the other cells for that dimension.
  const int cellSizeAll[] = {
                              (int)vd->getSize()[0] / (h_numCells[0]),
                              (int)vd->getSize()[1] / (h_numCells[1]),
                              (int)vd->getSize()[2] / (h_numCells[2])
                          };
  const int lastCellSize[] = {
                               cellSizeAll[0] + (int)vd->getSize()[0] % h_numCells[0],
                               cellSizeAll[1] + (int)vd->getSize()[1] % h_numCells[1],
                               cellSizeAll[2] + (int)vd->getSize()[2] % h_numCells[2]
                              };
  int cellSize[3];
  int from[3];
  int to[3];
  const vvVector3 size = vd->getSize();
  for (int z=0; z<h_numCells[2]; ++z)
  {
    cellSize[2] = (z == (h_numCells[2] - 1)) ? lastCellSize[2] : cellSizeAll[2];
    from[2] = cellSizeAll[2] * z;
    to[2] = from[2] + cellSize[2];

    for (int y=0; y<h_numCells[1]; ++y)
    {
      cellSize[1] = (y == (h_numCells[1] - 1)) ? lastCellSize[1] : cellSizeAll[1];
      from[1] = cellSizeAll[1] * y;
      to[1] = from[1] + cellSize[1];

      for (int x=0; x<h_numCells[2]; ++x)
      {
        cellSize[0] = (x == (h_numCells[0] - 1)) ? lastCellSize[0] : cellSizeAll[0];
        from[0] = cellSizeAll[0] * x;
        to[0] = from[0] + cellSize[0];

        // Memorize the max and min scalar values in the volume. These are stored
        // to perform space skipping later on.
        int minValue = INT_MAX;
        int maxValue = -INT_MAX;

        for (int vz=from[2]; vz<to[2]; ++vz)
        {
          for (int vy=from[1]; vy<to[1]; ++vy)
          {
            for (int vx=from[0]; vx<to[0]; ++vx)
            {
              const uchar vox = vd->getRaw()[vz * (int)(size[0] * size[1]) + vy * (int)size[0] + vx];

              // Store min and max for empty space leaping.
              if (vox > maxValue)
              {
                maxValue = vox;
              }
              if (vox < minValue)
              {
                minValue = vox;
              }
            }
          }
        }
        const int idx = x * h_numCells[1] * h_numCells[2] + y * h_numCells[2] + z;
        h_cellMinValues[idx] = minValue;
        h_cellMaxValues[idx] = maxValue;
      }
    }
  }
}

void vvRayRend::computeSpaceSkippingTexture()
{
  if (vd->bpc == 1)
  {
    delete[] h_spaceSkippingArray;
    const int numCells = h_numCells[0] * h_numCells[1] * h_numCells[2];
    h_spaceSkippingArray = new bool[numCells];
    int discarded = 0;
    for (int i=0; i<numCells; ++i)
    {
      h_spaceSkippingArray[i] = true;
      for (int j=h_cellMinValues[i]; j<=h_cellMaxValues[i]; ++j)
      {
        if(_rgbaTF[j * 4 + 3] > 0.0f)
        {
          h_spaceSkippingArray[i] = false;
          break;
        }
      }
      if (h_spaceSkippingArray[i])
      {
        ++discarded;
      }
    }
    vvDebugMsg::msg(3, "Cells discarded: ", discarded);
  }
  else
  {
    // Only for bpc == 1 so far.
    _spaceSkipping = false;
    delete[] h_spaceSkippingArray;
    h_spaceSkippingArray = NULL;
    delete[] h_cellMinValues;
    h_cellMinValues = NULL;
    delete[] h_cellMaxValues;
    h_cellMaxValues = NULL;
  }
}

void vvRayRend::setDepthPrecision(vvImage2_5d::DepthPrecision dp)
{
  _depthPrecision = dp;
}

#endif
