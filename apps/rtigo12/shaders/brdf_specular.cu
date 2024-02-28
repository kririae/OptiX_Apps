/* 
 * Copyright (c) 2013-2024, NVIDIA CORPORATION. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *  * Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *  * Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *  * Neither the name of NVIDIA CORPORATION nor the names of its
 *    contributors may be used to endorse or promote products derived
 *    from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"

#include <optix.h>

#include "system_data.h"
#include "per_ray_data.h"
#include "vertex_attributes.h"
#include "function_indices.h"
#include "material_definition.h"
#include "light_definition.h"
#include "shader_common.h"
#include "transform.h"
#include "random_number_generators.h"
#include "bxdf_common.h"

extern "C" __constant__ SystemData sysData;

// Combining state and sample data into one structure.
// That way the normals only need to be flipped once to the side of the ray (k1 outgoing direction)
// The ior doesn't need to be set twice,
struct __align__(4) State_Specular_BRDF
{
  // 4 byte aligned
  float3 tint;      // material.albedo
  // Geometry state in world space. 
  // normalGeo and normal are flipped to the ray side by the caller.
  float3 normalGeo;
  float3 normal;
  
  float3 k1;                  // sample and eval input: outgoing direction (== prd.wo == negative optixGetWorldRayDirection())
  float3 k2;                  // sample output: incoming direction (continuation ray, prd.wi)
                              // eval input:    incoming direction (direction to light sample point)
  float3 bsdf_over_pdf;       // sample output: bsdf * dot(k2, normal) / pdf
  float  pdf;                 // sample and eval output: pdf (non-projected hemisphere) Specular BXDFs return zero!
  Bsdf_event_type event_type; // sample output: the type of event for the generated sample (absorb, glossy_reflection, glossy_transmission)
};


__forceinline__ __device__ void brdf_specular_sample(State_Specular_BRDF& state)
{
  // When the sampling returns eventType = BSDF_EVENT_ABSORB, the path ends inside the ray generation program.
  // Make sure the returned values are valid numbers when manipulating the PRD.
  state.bsdf_over_pdf = make_float3(0.0f);
  state.pdf           = 0.0f;

  const float nk1 = dot(state.k1, state.normal);

  if (nk1 < 0.0f) // Shading normal not in the same hemisphere as the outgoing ray direction?
  {
    state.event_type = BSDF_EVENT_ABSORB;
    return;
  }

  // scatter_reflect
  state.k2            = (nk1 + nk1) * state.normal - state.k1;
  state.bsdf_over_pdf = state.tint;
  state.event_type    = BSDF_EVENT_SPECULAR_REFLECTION;

  // Check if the resulting direction is on the correct side of the actual geometry.
  const float gnk2 = dot(state.k2, state.normal);

  if (gnk2 <= 0.0f)
  {
    state.event_type = BSDF_EVENT_ABSORB;
  }
}

extern "C" __global__ void __closesthit__brdf_specular()
{
  PerRayData* thePrd = mergePointer(optixGetPayload_0(), optixGetPayload_1());

  GeometryInstanceData theData = sysData.geometryInstanceData[optixGetInstanceId()];

  // Cast the CUdeviceptr to the actual format for Triangles geometry.
  const unsigned int thePrimitiveIndex = optixGetPrimitiveIndex();

  const uint3* indices = reinterpret_cast<uint3*>(theData.indices);
  const uint3  tri = indices[thePrimitiveIndex];

  const TriangleAttributes* attributes = reinterpret_cast<TriangleAttributes*>(theData.attributes);

  const TriangleAttributes& attr0 = attributes[tri.x];
  const TriangleAttributes& attr1 = attributes[tri.y];
  const TriangleAttributes& attr2 = attributes[tri.z];

  const float2 theBarycentrics = optixGetTriangleBarycentrics(); // beta and gamma
  const float  bary_a = 1.0f - theBarycentrics.x - theBarycentrics.y;

  State_Specular_BRDF state;

  state.normalGeo = cross(attr1.vertex - attr0.vertex, attr2.vertex - attr0.vertex);
  state.normal    = attr0.normal   * bary_a + attr1.normal   * theBarycentrics.x + attr2.normal   * theBarycentrics.y;
  float3 texcoord = attr0.texcoord * bary_a + attr1.texcoord * theBarycentrics.x + attr2.texcoord * theBarycentrics.y;

  float4 objectToWorld[3];
  float4 worldToObject[3];

  getTransforms(optixGetTransformListHandle(0), objectToWorld, worldToObject); // Single instance level transformation list only.

  // All in world space coordinates!
  state.normalGeo = normalize(transformNormal(worldToObject, state.normalGeo));
  state.normal    = normalize(transformNormal(worldToObject, state.normal));

  thePrd->flags   |= FLAG_HIT;
  thePrd->distance = optixGetRayTmax();
  thePrd->pos     += thePrd->wi * thePrd->distance;

  // If we're inside a volume and hit something, the path throughput needs to be modulated
  // with the transmittance along this segment before adding surface or light radiance!
  if (0 < thePrd->idxStack) // This assumes the first stack entry is vaccuum.
  {
    thePrd->throughput *= expf(thePrd->sigma_t * -thePrd->distance);

    // Increment the volume scattering random walk counter.
    // Unused when FLAG_VOLUME_SCATTERING is not set.
    ++thePrd->walk;
  }

  const MaterialDefinition& material = sysData.materialDefinitions[theData.idMaterial];

  state.tint = material.albedo;

  if (material.textureAlbedo != 0)
  {
    const float3 texColor = make_float3(tex2D<float4>(material.textureAlbedo, texcoord.x, texcoord.y));

    // Modulate the incoming color with the texture.
    state.tint *= texColor;               // linear color, resp. if the texture has been uint8 and readmode set to use sRGB, then sRGB.
    //state.tint *= powf(texColor, 2.2f); // sRGB gamma correction done manually.
  }

  // Explicitly include edge-on cases as frontface condition!
  // Keeps the material stack from overflowing at silhouettes.
  // Prevents that silhouettes of thin-walled materials use the backface material.
  // Using the true geometry normal attribute as originally defined on the frontface!
  const bool isFrontFace = (0.0f <= dot(thePrd->wo, state.normalGeo));

  // Flip the normals to the side the ray hit.
  if (!isFrontFace)
  {
    state.normalGeo = -state.normalGeo;
    state.normal    = -state.normal;
  }

  state.k1 = thePrd->wo;         // == -optixGetWorldRayDirection()

  brdf_specular_sample(state);

  thePrd->wi          = state.k2;            // Continuation direction.
  thePrd->throughput *= state.bsdf_over_pdf; // Adjust the path throughput for all following incident lighting.
  thePrd->pdf         = state.pdf;           // Note that specular events return pdf == 0.0f! (=> Not a path termination condition.)
  thePrd->eventType   = state.event_type;    // If this is BSDF_EVENT ABSORB, the path ends inside the integrator and the radiance is returned.
                                             // Keep calculating the radiance of the current hit point though.
  // BRDFs don't change the material stack.
}
