#include "includes/ShaderStructs.hlsli"
#include "includes/ShaderCommon.hlsli"
#include "includes/CommonFunctions.hlsli"

Texture3D shapeNoiseTex : register(t4);
Texture3D detailNoiseTex : register(t5);
cbuffer ExtraData : register(b10)
{
    float3 boundsMin;
    float base_Scale;
    float3 boundsMax;
    float cloud_densityThr;
    float3 cloud_offset;
    float cloud_densityMul;
    
    float lightAbsorptionThroughCloud;
    float darknessThreshold;
    int volume_march_steps;
    int light_march_steps;
    
    float3 detail_offset;
    float detail_scale;
    
    float base_weight;
    float detail_weight;
    
    float frwrd_scatter;
    float back_scatter;
    float base_brightness;
    float phase_factor;
    
    bool random_sample;
    bool optimized_march;
};

//COMMON FUNC
float rand_1_05(in float2 uv)
{
    float2 noise = (frac(sin(dot(uv, float2(12.9898, 78.233) * 2.0)) * 43758.5453));
    return abs(noise.x + noise.y) * 0.5;
}

float remap(float v, float minOld, float maxOld, float minNew, float maxNew)
{
    return minNew + (v - minOld) * (maxNew - minNew) / (maxOld - minOld);
}

float Flip(float inVal)
{
    return (inVal * -1.0f) + 1.0f;
}

float3 Flip(float3 inVal)
{
    return (inVal * -1.0f) + 1.0f;
}

float BeersLaw(float aDist)
{
    return exp(-aDist);
}

float Powder(float aDist)
{
    return 1.0f - exp(-aDist * 2.0f);
}

float BeersPowder(float aDist)
{
    return BeersLaw(aDist) * Powder(aDist);
}

struct BoundsInfo
{
    float dstToObj;
    float dstInsideObj;
};

BoundsInfo RayBoxDist(float3 boundsMin, float3 boundsMax, float3 rayOrigin, float3 rayDir)
{
    float3 t0 = (boundsMin - rayOrigin) / rayDir;
    float3 t1 = (boundsMax - rayOrigin) / rayDir;
    float3 tmin = min(t0, t1);
    float3 tmax = max(t0, t1);

    float dstA = max(max(tmin.x, tmin.y), tmin.z);
    float dstB = min(tmax.x, min(tmax.y, tmax.z));

    float dstToBox = max(0.0f, dstA);
    
    BoundsInfo info;
    info.dstToObj = dstToBox;
    info.dstInsideObj = max(0.0f, dstB - dstToBox);
    return info;
}
//COMMON FUNC

//PHASE FUNC
float HenyeyGreenstein(float g, float costh)
{
    float g2 = g * g;
    return (1 - g2) / (4 * 3.1415f * pow(1 + g2 - 2 * g * (costh), 1.5));
}

const float DUAL_LOBE_WEIGHT = 0.7;
float DualLob_HG(float g, float costh)
{
    return lerp(HenyeyGreenstein(g, costh), HenyeyGreenstein(g, costh), DUAL_LOBE_WEIGHT);
}

float PhaseFunction(float g, float costh)
{
    return DualLob_HG(g, costh);
}

float PhaseFunction(float costh, float aFrontScatter, float aBackScatter, float aBaseBright, float aPhaseFac)
{
    float hgBlend = HenyeyGreenstein(aFrontScatter, costh) * (1 - DUAL_LOBE_WEIGHT) + HenyeyGreenstein(-aBackScatter, costh) * DUAL_LOBE_WEIGHT;
    return aBaseBright + hgBlend * aPhaseFac;
}

//Pixar (Oz)
#define EXTINCTION_MULT 0.0f
float MultipleOctaveScattering(float aDensity, float mu)
{
    const float atten = 0.2f;
    const float contribution = 0.4f;
    const float phaseAtten = 0.1f;
    
    const float scatteringOctaves = 4.0f;
    float a = 1.0f;
    float b = 1.0f;
    float c = 1.0f;
    
    float lum = 0.0f;
    for (float i = 0.0f; i < scatteringOctaves; i++)
    {
        float phaseFunc = PhaseFunction(0.3f * c, mu);
        float beers = BeersLaw(aDensity * EXTINCTION_MULT * a);
        
        lum += b * phaseFunc * beers;
        
        a *= atten;
        b *= contribution;
        c *= (1.0f - phaseAtten);
    }

    return lum;
}
//PHASE FUNC

//CLOUD_SHAPING
float EdgeFallof(float3 aPos)
{
    const float containerEdgeFadeDst = 50.0f;
    float dstFromEdgeX = min(containerEdgeFadeDst, min(aPos.x - boundsMin.x, boundsMax.x - aPos.x));
    float dstFromEdgeZ = min(containerEdgeFadeDst, min(aPos.z - boundsMin.z, boundsMax.z - aPos.z));
    float edgeWeight = min(dstFromEdgeX, dstFromEdgeX) / containerEdgeFadeDst;
    return edgeWeight;
}

float HeightFallof(float3 aPos)
{
    float3 size = boundsMax - boundsMin;
    
    float minHeight = 0.25f;
    float maxHeight = 0.75f;
    float percent = (aPos.y - boundsMin.y) / size.y;
    
    float percentMin = saturate(remap(percent, 0.0f, minHeight, 0.0f, 1.0f));
    float percentMax = saturate(remap(percent, 1.0f, maxHeight, 0.0f, 1.0f));
    float gradient = percentMin * percentMax;
    return gradient;
}
//CLOUD_SHAPING

//SAMPLING
float3 CalculateUVW(float3 aPos)
{
    static const float baseScale = 1 / 1000.0;
    float3 size = boundsMax - boundsMin;
    
    float3 uvw = (size * 0.5f + aPos) * baseScale * base_Scale;
    return uvw;
}

float SampleLowRes(float3 aPos)
{
    static const float offsetSpeed = 1 / 100.0;
    float3 uvw = CalculateUVW(aPos);
    float3 shapeSamplePos = uvw + cloud_offset * offsetSpeed;
    float shapeNoise = shapeNoiseTex.Sample(sampleState, shapeSamplePos).r;
    
    float density = (shapeNoise - cloud_densityThr) * cloud_densityMul;
    return density;
}

float4 SampleLowResUVW(float3 aPos)
{
    static const float offsetSpeed = 1 / 100.0;
    float3 uvw = CalculateUVW(aPos);
    
    float3 shapeSamplePos = uvw + cloud_offset * offsetSpeed;
    float shapeNoise = shapeNoiseTex.Sample(sampleState, shapeSamplePos).r;
    
    float density = (shapeNoise - cloud_densityThr) * cloud_densityMul;
    return float4(density, uvw);
}

float SampleHighRes(float3 aUVW)
{
    float3 detailSampleNoise = aUVW * detail_scale + detail_offset;
    float4 detailNoise = detailNoiseTex.Sample(sampleState, detailSampleNoise);
    float3 normalizedDetailWeights = detail_weight / dot(detail_weight, 1.0f);
    float detailFBM = dot(detailNoise.rgb, normalizedDetailWeights);
    return detailFBM;
}

float TrimCloud(float3 aPos, float aDensity, float aDetailFBM)
{
    float oneMinuseShape = 1 - aDensity;
    float detailErodeWeights = oneMinuseShape * oneMinuseShape * oneMinuseShape;
    float cloudDensity = aDensity - (1.0f - aDetailFBM) * detailErodeWeights * detail_weight;
    
    return cloudDensity * EdgeFallof(aPos) * HeightFallof(aPos);
}

//Default
float SampleDensity(float3 aPos)
{
    float4 lowResUVW = SampleLowResUVW(aPos);
    float density = lowResUVW.x;
    float3 uvw = lowResUVW.yzw;
    if (density <= 0.0f)
        return 0.0f;
    
    float detailFBM = SampleHighRes(uvw);
    float trimmed = TrimCloud(aPos, density, detailFBM);
    return trimmed;
}
//SAMPLING

//MARCHING FUNC
float LightMarch(float3 aPos, float costh)
{
    float3 dirToLight = normalize(aPos - dirLPos);
    float dstInsideBox = RayBoxDist(boundsMin, boundsMax, aPos, dirToLight).dstInsideObj;
    
    float stepSize = dstInsideBox / (float) light_march_steps;
    float totalDensity = 0.0f;
    float dstTravelled = 0.0f;
    
    [loop]
    for (int step = 0; step < light_march_steps; step++)
    {
        if (dstTravelled > dstInsideBox)
            break;
        
        dstTravelled += dirToLight * stepSize;
        aPos += dstTravelled;
        totalDensity += max(0.0f, SampleDensity(aPos) * stepSize);
    }
    
    float densMul = totalDensity * lightAbsorptionThroughCloud;
    float beersLaw = MultipleOctaveScattering(densMul, costh);
    
    float transmittance = beersLaw * lerp(2.0f * Powder(densMul), float3(1.0f, 1.0f, 1.0f), remap(costh, -1.0f, 1.0f, 0.0f, 1.0f));
    return darknessThreshold + transmittance * (1 - darknessThreshold);
}

float4 VolumeMarchLight(float3 anEntryPoint, float3 aRayDir, float aDistance, float aRandOffset)
{    
    float3 lightColor = float3(dirLColR, dirLColG, dirLColB);
    
    float dstTravelled = aRandOffset;
    float stepSize = aDistance / (float)volume_march_steps;
    float3 rayPos = anEntryPoint;
    
    float3 dirToLight = normalize(dirLPos - anEntryPoint);
    float cosAngle = dot(aRayDir, dirToLight);
    float phaseVal = PhaseFunction(cosAngle, frwrd_scatter, back_scatter, base_brightness, phase_factor);
    
    float transmittance = 1;
    float lightEnergy = 0;
    
    float density = 0.0f;
    float lightTransmittance = 0.0f;
    
    float3 fogColor = 0.0f;
    int fogSteps = 0;
    [loop]
    for (int i = 0; i < volume_march_steps; ++i)
    {
        if (dstTravelled > aDistance)
            break;
        
        rayPos = anEntryPoint + aRayDir * dstTravelled;
        density = SampleDensity(rayPos);
        
        if (density > 0.0f)
        {
            lightTransmittance = LightMarch(rayPos, cosAngle);
            lightEnergy += density * stepSize * transmittance * lightTransmittance * phaseVal;
            transmittance *= BeersLaw(density * stepSize * lightAbsorptionThroughCloud);
            
            float3 tempCol = lightEnergy * lightColor;
            float3 toEyeNoNorm = cameraPosition - rayPos;
            fogColor += ApplyFog(tempCol, cameraPosition.y, toEyeNoNorm);
            fogSteps++;
            
            if (transmittance < 0.01f)
            {
                break;
            }
        }
        dstTravelled += stepSize;
    }
   
    fogColor = saturate(fogColor / fogSteps);
    float3 cloudCol = lightEnergy + fogColor;
    
    float3 col = transmittance + cloudCol;
    return float4(col, transmittance);
}

float4 OptimizedVolumeMarch(float3 anEntryPoint, float3 aRayDir, float aDistance, float aRandOffset)
{
    float3 lightColor = float3(dirLColR, dirLColG, dirLColB);

    const float inclineRate = 0.01f;
    const int NUM_COUNT = 5;
    float stepSize = (aDistance / (float) volume_march_steps) * (float) NUM_COUNT;
    float newStepSize = stepSize + (aDistance * inclineRate);
    float hqStepSize = newStepSize / (float) NUM_COUNT;
    
    float3 rayPos = anEntryPoint;
    float dstTravelled = aRandOffset;
    
    float3 dirToLight = normalize(dirLPos - anEntryPoint);
    float cosAngle = dot(aRayDir, dirToLight);
    float phaseVal = PhaseFunction(cosAngle, frwrd_scatter, back_scatter, base_brightness, phase_factor);
    
    float density = 0.0f;
    float lightEnergy = 0;
    float transmittance = 1;
    float lightTransmittance = 0.0f;
    float3 fogColor = 0.0f;
    
    int windbackCountdown = 0;
    [loop]
    for (int i = 0; i < volume_march_steps; ++i)
    {
        if (dstTravelled > aDistance)
            break;
        
        rayPos = anEntryPoint + aRayDir * dstTravelled;
        density = SampleLowRes(rayPos);
        
        float currStepLen = hqStepSize;
        if (windbackCountdown <= 0)
        {
            if (density <= 0.0f)
            {
                dstTravelled += currStepLen;
                continue;
            }
            windbackCountdown = NUM_COUNT;
            dstTravelled += hqStepSize;
        }
        
        if (windbackCountdown > 0)
        {
            --windbackCountdown;
            if(density > 0.0f)
            {
                windbackCountdown = NUM_COUNT;
                
                float3 calculateUVW = CalculateUVW(rayPos);
                float detailFBM = SampleHighRes(calculateUVW);
                float trimmedCloud = TrimCloud(rayPos, density, detailFBM);
                if (trimmedCloud > 0.0f)
                {                    
                    lightTransmittance = LightMarch(rayPos, cosAngle);
                    lightEnergy += trimmedCloud * stepSize * transmittance * lightTransmittance * phaseVal;
                    transmittance *= BeersLaw(trimmedCloud * stepSize * lightAbsorptionThroughCloud);
                    
                    float3 tempCol = lightEnergy * lightColor;
                    float3 toEyeNoNorm = cameraPosition - rayPos;
                    fogColor += ApplyFog(tempCol, cameraPosition.y, toEyeNoNorm);
                }
            
                if (transmittance < 0.01f)
                    break;
            }
            dstTravelled += hqStepSize;
        }
    }  
    
    fogColor = saturate(fogColor / volume_march_steps);
    float3 cloudCol = lightEnergy + fogColor;
    
    float3 col = transmittance + cloudCol;
    return float4(col, transmittance);
}
//MARCHING FUNC

PixelOutput main(PixelInputType input)
{
    PixelOutput result;
    float4 col;

    float3 rayOrigin = cameraPosition.xyz;
    float3 rayDir = normalize(input.worldPosition.xyz - rayOrigin);
    
    BoundsInfo rayBoxInfo = RayBoxDist(boundsMin, boundsMax, rayOrigin, rayDir);
    float3 entryPoint = rayOrigin + rayDir * rayBoxInfo.dstToObj;
    
    float randomOffset = 0.0f; 
    if (random_sample)
        randomOffset = rand_1_05(input.uv * 3.0f);
    
    if (optimized_march)
        col = OptimizedVolumeMarch(entryPoint, rayDir, rayBoxInfo.dstInsideObj, randomOffset);
    else
        col = VolumeMarchLight(entryPoint, rayDir, rayBoxInfo.dstInsideObj, randomOffset);
    
    result.color.rgb = col.rgb;
    result.color.a = Flip(col.a);
    
    return result;
}