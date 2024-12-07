#include "includes/ShaderCommon.hlsli"
#include "includes/ShaderStructs.hlsli"
Texture2D textureToBlur : register(t0);

PixelOutput main(PIFullscreen input)
{
    PixelOutput output;
    output.color.a = 1.0f;
    
    float2 scaledUV = input.position.xy / myResolution;
    
    float2 texelSize = 1.0f / myResolution; 
    float4 result = 0.0;
    for (int i = -2; i < 2; ++i)
    {
        for (int j = -2; j < 2; ++j)
        {
            float2 offset = float2(float(i), float(j)) * texelSize;
            result += textureToBlur.Sample(sampleState, scaledUV + offset);
        }
    }
    
    result = result / (4.0 * 4.0);
    output.color.rgb = result.rgb;
    return output;
}