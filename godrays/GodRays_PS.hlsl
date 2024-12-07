#include "includes/ShaderStructs.hlsli"
#include "includes/ShaderCommon.hlsli"
#include "includes/CommonFunctions.hlsli"

#include "includes/PBRCommon.hlsli"
#include "includes/OLDPBR.hlsli"
#include "includes/PBRFunctions.hlsli"

#include "includes/DeferredCommon.hlsli"
#include "includes/ShadowCommon.hlsli"

Texture2D oulineTexture : register(t18);
Texture2D ssaoTexture : register(t5);

float InterleavedGradientNoise(int pixelX, int pixelY)
{
    return fmod(52.9829189f * fmod(0.06711056f * float(pixelX) +0.00583715f * float(pixelY), 1.0f), 1.0f);
}

PixelOutput main(PIFullscreen input)
{
    PixelOutput output;
    output.color.a = 1.0f;
    
    float2 uv = input.position.xy / myResolution;
    float depth = depthPass.Sample(sampleState, uv).r;
    float3 gbuffer_worldpos = GetWorldPosFromDepth(depth, uv);
    float3 finalColor = 0.0f;
    
    float3 endPos = gbuffer_worldpos;
    float3 startPos = cameraPosition;
    
    float3 dirLCol = float3(dirLColR, dirLColG, dirLColB);
    float3 accumulated_light = float3(0.0f, 0.0f, 0.0f);
    
#define RAYMARCH_AMOUNT 32
    float stepSize = length(endPos - startPos) / RAYMARCH_AMOUNT;
    float3 toeye = normalize(endPos - startPos);
    float3 samplePoint = startPos;
    
    float3 sampleToLight = float3(0.0f, 0.0f, 0.0f);
    float lightDist = 0.0f;
   
    float dist = 0.0f;
    float density = 1.0f;
    
    int2 pixelUV = input.position.xy * myResolution;
    float randomness = InterleavedGradientNoise(pixelUV.x, pixelUV.y);
    float step = stepSize;
    
    [unroll(RAYMARCH_AMOUNT)]
    for (int i = 0; i < RAYMARCH_AMOUNT; i++)
    {
        dist += step;
        samplePoint += toeye * step;

        //Sample Shadow at each step
        float4 worldpos = float4(samplePoint, 1.0f);
        float4 dirLightProjectedPos = mul(worldToLight, worldpos);
        float3 dirLightProjPos = dirLightProjectedPos.xyz / dirLightProjectedPos.w;
        float dirLShadow = CalcShadow(shadowMap, dirLightProjPos.xyz, 0);
        if (dirLShadow <= 0.0f)
            continue;
        
        step += randomness;
        
        float ndl = dot(toeye, dirLDir);
        float beers = BeersLaw(dist * 0.01f);
        float phase = HenyeyGreenstein(0.3f, ndl);
        float transmittance = phase * beers;
        accumulated_light += transmittance * dirLCol;
    }
   
    finalColor = accumulated_light;
    output.color.rgb = finalColor;
    return output;
}