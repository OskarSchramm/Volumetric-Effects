#include "includes/ShaderCommon.hlsli"
Texture2D ssaoTexture : register(t5);
RWTexture2D<float> uavOut : register(u0);

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint x = dispatchThreadID.x;
    uint y = dispatchThreadID.y;
    uint2 uv = uint2(x, y);
    float2 scaledUV = (uv / myResolution);
    
    if (scaledUV.x >= myResolution.x || scaledUV.y >= myResolution.y)
        return;
    
    
    float2 texelSize = 1.0f / myResolution; 
    float result = 0.0;
    for (int i = -2; i < 2; ++i)
    {
        for (int j = -2; j < 2; ++j)
        {
            float2 offset = float2(float(i), float(j)) * texelSize;
            result += ssaoTexture.SampleLevel(sampleState, scaledUV + offset, 0).r;
            //result = uavOut.Load(uint3(uint2(scaledUV + offset), 1));
        }
    }
    
    result = result / (4.0 * 4.0);
    uavOut[uv] = result;
}