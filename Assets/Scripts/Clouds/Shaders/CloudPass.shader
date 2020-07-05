Shader "FullScreen/CloudPass"
{
    HLSLINCLUDE

    #pragma vertex Vert

    #pragma target 4.5
    #pragma only_renderers d3d11 ps4 xboxone vulkan metal switch

    #include "Packages/com.unity.render-pipelines.high-definition/Runtime/RenderPipeline/RenderPass/CustomPass/CustomPassCommon.hlsl"

    // The PositionInputs struct allow you to retrieve a lot of useful information for your fullScreenShader:
    // struct PositionInputs
    // {
    //     float3 positionWS;  // World space position (could be camera-relative)
    //     float2 positionNDC; // Normalized screen coordinates within the viewport    : [0, 1) (with the half-pixel offset)
    //     uint2  positionSS;  // Screen space pixel coordinates                       : [0, NumPixels)
    //     uint2  tileCoord;   // Screen tile coordinates                              : [0, NumTiles)
    //     float  deviceDepth; // Depth from the depth buffer                          : [0, 1] (typically reversed)
    //     float  linearDepth; // View space Z coordinate                              : [Near, Far]
    // };

    // To sample custom buffers, you have access to these functions:
    // But be careful, on most platforms you can't sample to the bound color buffer. It means that you
    // can't use the SampleCustomColor when the pass color buffer is set to custom (and same for camera the buffer).
    // float4 SampleCustomColor(float2 uv);
    // float4 LoadCustomColor(uint2 pixelCoords);
    // float LoadCustomDepth(uint2 pixelCoords);
    // float SampleCustomDepth(float2 uv);

    // There are also a lot of utility function you can use inside Common.hlsl and Color.hlsl,
    // you can check them out in the source code of the core SRP package.

	// Textures
	Texture3D<float4> NoiseTex;
	Texture3D<float4> DetailNoiseTex;
	Texture2D<float4> WeatherMap;
	Texture2D<float4> BlueNoise;
	
	SamplerState samplerNoiseTex;
	SamplerState samplerDetailNoiseTex;
	SamplerState samplerWeatherMap;
	SamplerState samplerBlueNoise;

	sampler2D _MainTex;

	// Shape settings
	float4 params;
	int3 mapSize;
	float densityMultiplier;
	float densityOffset;
	float scale;
	float detailNoiseScale;
	float detailNoiseWeight;
	float3 detailWeights;
	float4 shapeNoiseWeights;
	float4 phaseParams;

	// March settings
	int numStepsLight;
	float rayOffsetStrength;

	float3 boundsMin;
	float3 boundsMax;

	float3 shapeOffset;
	float3 detailOffset;

	// Light settings
	float lightAbsorptionTowardSun;
	float lightAbsorptionThroughCloud;
	float darknessThreshold;
	float4 colA;
	float4 colB;

	// Animation settings
	float timeScale;
	float baseSpeed;
	float detailSpeed;

	// Debug settings:
	int debugViewMode; // 0 = off; 1 = shape tex; 2 = detail tex; 3 = weathermap
	int debugGreyscale;
	int debugShowAllChannels;
	float debugNoiseSliceDepth;
	float4 debugChannelWeight;
	float debugTileAmount;
	float viewerSize;
	
	float remap(float v, float minOld, float maxOld, float minNew, float maxNew) {
		return minNew + (v-minOld) * (maxNew - minNew) / (maxOld-minOld);
	}

	float2 squareUV(float2 uv) {
		float width = _ScreenParams.x;
		float height =_ScreenParams.y;
		//float minDim = min(width, height);
		float scale = 1000;
		float x = uv.x * width;
		float y = uv.y * height;
		return float2 (x/scale, y/scale);
	}

	// Returns (dstToBox, dstInsideBox). If ray misses box, dstInsideBox will be zero
	float2 rayBoxDst(float3 boundsMin, float3 boundsMax, float3 rayOrigin, float3 invRaydir) {
		// Adapted from: http://jcgt.org/published/0007/03/04/
		float3 t0 = (boundsMin - rayOrigin) * invRaydir;
		float3 t1 = (boundsMax - rayOrigin) * invRaydir;
		float3 tmin = min(t0, t1);
		float3 tmax = max(t0, t1);
		
		float dstA = max(max(tmin.x, tmin.y), tmin.z);
		float dstB = min(tmax.x, min(tmax.y, tmax.z));

		// CASE 1: ray intersects box from outside (0 <= dstA <= dstB)
		// dstA is dst to nearest intersection, dstB dst to far intersection

		// CASE 2: ray intersects box from inside (dstA < 0 < dstB)
		// dstA is the dst to intersection behind the ray, dstB is dst to forward intersection

		// CASE 3: ray misses box (dstA > dstB)

		float dstToBox = max(0, dstA);
		float dstInsideBox = max(0, dstB - dstToBox);
		return float2(dstToBox, dstInsideBox);
	}

	// Henyey-Greenstein
	float hg(float a, float g) {
		float g2 = g*g;
		return (1-g2) / (4*3.1415*pow(1+g2-2*g*(a), 1.5));
	}

	float phase(float a) {
		float blend = .5;
		float hgBlend = hg(a,phaseParams.x) * (1-blend) + hg(a,-phaseParams.y) * blend;
		return phaseParams.z + hgBlend*phaseParams.w;
	}

	float beer(float d) {
		float beer = exp(-d);
		return beer;
	}

	float remap01(float v, float low, float high) {
		return (v-low)/(high-low);
	}

	float sampleDensity(float3 rayPos) {
		// Constants:
		const int mipLevel = 0;
		const float baseScale = 1/1000.0;
		const float offsetSpeed = 1/100.0;

		// Calculate texture sample positions
		float time = _Time.x * timeScale;
		float3 size = boundsMax - boundsMin;
		float3 boundsCentre = (boundsMin+boundsMax) * .5;
		float3 uvw = (size * .5 + rayPos) * baseScale * scale;
		float3 shapeSamplePos = uvw + shapeOffset * offsetSpeed + float3(time,time*0.1,time*0.2) * baseSpeed;

		// Calculate falloff at along x/z edges of the cloud container
		const float containerEdgeFadeDst = 50;
		float dstFromEdgeX = min(containerEdgeFadeDst, min(rayPos.x - boundsMin.x, boundsMax.x - rayPos.x));
		float dstFromEdgeZ = min(containerEdgeFadeDst, min(rayPos.z - boundsMin.z, boundsMax.z - rayPos.z));
		float edgeWeight = min(dstFromEdgeZ,dstFromEdgeX)/containerEdgeFadeDst;
		
		// Calculate height gradient from weather map
		//float2 weatherUV = (size.xz * .5 + (rayPos.xz-boundsCentre.xz)) / max(size.x,size.z);
		//float weatherMap = WeatherMap.SampleLevel(samplerWeatherMap, weatherUV, mipLevel).x;
		float gMin = .2;
		float gMax = .7;
		float heightPercent = (rayPos.y - boundsMin.y) / size.y;
		float heightGradient = saturate(remap(heightPercent, 0.0, gMin, 0, 1)) * saturate(remap(heightPercent, 1, gMax, 0, 1));
		heightGradient *= edgeWeight;

		// Calculate base shape density
		float4 shapeNoise = NoiseTex.SampleLevel(samplerNoiseTex, shapeSamplePos, mipLevel);
		float4 normalizedShapeWeights = shapeNoiseWeights / dot(shapeNoiseWeights, 1);
		float shapeFBM = dot(shapeNoise, normalizedShapeWeights) * heightGradient;
		float baseShapeDensity = shapeFBM + densityOffset * .1;

		// Save sampling from detail tex if shape density <= 0
		if (baseShapeDensity > 0) {
			// Sample detail noise
			float3 detailSamplePos = uvw*detailNoiseScale + detailOffset * offsetSpeed + float3(time*.4,-time,time*0.1)*detailSpeed;
			float4 detailNoise = DetailNoiseTex.SampleLevel(samplerDetailNoiseTex, detailSamplePos, mipLevel);
			float3 normalizedDetailWeights = detailWeights / dot(detailWeights, 1);
			float detailFBM = dot(detailNoise, normalizedDetailWeights);

			// Subtract detail noise from base shape (weighted by inverse density so that edges get eroded more than centre)
			float oneMinusShape = 1 - shapeFBM;
			float detailErodeWeight = oneMinusShape * oneMinusShape * oneMinusShape;
			float cloudDensity = baseShapeDensity - (1-detailFBM) * detailErodeWeight * detailNoiseWeight;

			return cloudDensity * densityMultiplier * 0.1;
		}
		return 0;
	}

	// Calculate proportion of light that reaches the given point from the lightsource
	float lightmarch(float3 position) {
		float3 dirToLight = -_DirectionalLightDatas[0].forward;
		float dstInsideBox = rayBoxDst(boundsMin, boundsMax, position, 1/dirToLight).y;
		
		float stepSize = dstInsideBox/numStepsLight;
		float totalDensity = 0;

		for (int step = 0; step < numStepsLight; step ++) {
			position += dirToLight * stepSize;
			totalDensity += max(0, sampleDensity(position) * stepSize);
		}

		float transmittance = exp(-totalDensity * lightAbsorptionTowardSun);
		return darknessThreshold + transmittance * (1-darknessThreshold);
	}

	float4 debugDrawNoise(float2 uv) {

		float4 channels = 0;
		float3 samplePos = float3(uv.x,uv.y, debugNoiseSliceDepth);

		if (debugViewMode == 1) {
			channels = NoiseTex.SampleLevel(samplerNoiseTex, samplePos, 0);
		}
		else if (debugViewMode == 2) {
			channels = DetailNoiseTex.SampleLevel(samplerDetailNoiseTex, samplePos, 0);
		}
		else if (debugViewMode == 3) {
			channels = WeatherMap.SampleLevel(samplerWeatherMap, samplePos.xy, 0);
		}

		if (debugShowAllChannels) {
			return channels;
		}
		else {
			float4 maskedChannels = (channels*debugChannelWeight);
			if (debugGreyscale || debugChannelWeight.w == 1) {
				return dot(maskedChannels,1);
			}
			else {
				return maskedChannels;
			}
		}
	}
  
	float4 marchClouds(PositionInputs i)
	{
		float2 uv = i.positionNDC;
		if (debugViewMode != 0) {
			float width = _ScreenParams.x;
			float height =_ScreenParams.y;
			float minDim = min(width, height);
			float x = uv.x * width;
			float y = (1 - uv.y) * height;

			if (x < minDim*viewerSize && y < minDim*viewerSize) {
				return debugDrawNoise(float2(x/(minDim*viewerSize)*debugTileAmount, y/(minDim*viewerSize)*debugTileAmount));
			}
		}
		
		// Create ray
		float3 rayPos = _WorldSpaceCameraPos;
        float3 rayDir = -GetWorldSpaceNormalizeViewDir(i.positionWS);
		
		// Depth and cloud container intersection info:
		float depth = i.linearDepth;
		float2 rayToContainerInfo = rayBoxDst(boundsMin, boundsMax, rayPos, 1 / rayDir);
		float dstToBox = rayToContainerInfo.x;
		float dstInsideBox = rayToContainerInfo.y;

		// point of intersection with the cloud container
		float3 entryPoint = rayPos + rayDir * dstToBox;

		// random starting offset (makes low-res results noisy rather than jagged/glitchy, which is nicer)
		float randomOffset = BlueNoise.SampleLevel(samplerBlueNoise, squareUV(uv * 3), 0);
		randomOffset *= rayOffsetStrength;
		
		// Phase function makes clouds brighter around sun
		float3 dirToLight = -_DirectionalLightDatas[0].forward;
		float cosAngle = dot(rayDir, dirToLight);
		float phaseVal = phase(cosAngle);

		float dstTravelled = randomOffset;
		float dstLimit = min(depth-dstToBox, dstInsideBox);
		
		const float stepSize = 11;

		// March through volume:
		float transmittance = 1;
		float3 lightEnergy = 0;

		while (dstTravelled < dstLimit) {
			rayPos = entryPoint + rayDir * dstTravelled;
			float density = sampleDensity(rayPos);
			
			if (density > 0) {
				float lightTransmittance = lightmarch(rayPos);
				lightEnergy += density * stepSize * transmittance * lightTransmittance * phaseVal;
				transmittance *= exp(-density * stepSize * lightAbsorptionThroughCloud);
			
				// Exit early if T is close to zero as further samples won't affect the result much
				if (transmittance < 0.01) {
					break;
				}
			}
			dstTravelled += stepSize;
		}

		float3 cloudCol = lightEnergy * _DirectionalLightDatas[0].color;
		return float4(cloudCol, 1 - transmittance);
	}

    float4 FullScreenPass(Varyings varyings) : SV_Target
    {
        UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(varyings);
        float depth = LoadCameraDepth(varyings.positionCS.xy);
        PositionInputs posInput = GetPositionInput(varyings.positionCS.xy, _ScreenSize.zw, depth, UNITY_MATRIX_I_VP, UNITY_MATRIX_V);
        float4 color = float4(0, 0, 0, 0);

        // Load the camera color buffer at the mip 0 if we're not at the before rendering injection point
        if (_CustomPassInjectionPoint != CUSTOMPASSINJECTIONPOINT_BEFORE_RENDERING)
            color = float4(CustomPassLoadCameraColor(varyings.positionCS.xy, 0), 1);

		// Add clouds to background
		color = marchClouds(posInput);

        // Fade value allow you to increase the strength of the effect while the camera gets closer to the custom pass volume
        float f = 1 - abs(_FadeValue * 2 - 1);
        return float4(color.rgb + f, color.a);
    }

    ENDHLSL

    SubShader
    {
        Pass
        {
            Name "Cloud Pass"

            ZWrite Off
            ZTest Always
            Blend SrcAlpha OneMinusSrcAlpha
            Cull Off

            HLSLPROGRAM
                #pragma fragment FullScreenPass
            ENDHLSL
        }
    }
    Fallback Off
}
