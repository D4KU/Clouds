using UnityEngine;
using UnityEngine.Rendering.HighDefinition;
using UnityEngine.Rendering;
using UnityEngine.Experimental.Rendering;

class CloudPass : CustomPass
{
    const string headerDecoration = " --- ";
    //[Header (headerDecoration + "Main" + headerDecoration)]
    public Shader shader;
    public Transform container;
    public Vector3 cloudTestParams;

    //[Header ("March settings" + headerDecoration)]
    public int numStepsLight = 8;
    public float rayOffsetStrength;
    public Texture2D blueNoise;

    //[Header (headerDecoration + "Base Shape" + headerDecoration)]
    public float cloudScale = 1;
    public float densityMultiplier = 1;
    public float densityOffset;
    public Vector3 shapeOffset;
    public Vector2 heightOffset;
    public Vector4 shapeNoiseWeights = new Vector4(1, 0.5f, 0.15f, 0);

    //[Header (headerDecoration + "Detail" + headerDecoration)]
    public float detailNoiseScale = 10;
    public float detailNoiseWeight = .1f;
    public Vector3 detailNoiseWeights;
    public Vector3 detailOffset;

    //[Header (headerDecoration + "Lighting" + headerDecoration)]
    public float lightAbsorptionThroughCloud = 1;
    public float lightAbsorptionTowardSun = 1;
    [Range (0, 1)]
    public float darknessThreshold = .2f;
    [Range (0, 1)]
    public float forwardScattering = .83f;
    [Range (0, 1)]
    public float backScattering = .3f;
    [Range (0, 1)]
    public float baseBrightness = .8f;
    [Range (0, 1)]
    public float phaseFactor = .15f;

    //[Header (headerDecoration + "Animation" + headerDecoration)]
    public float timeScale = 1;
    public float baseSpeed = 1;
    public float detailSpeed = 2;

    //[Header (headerDecoration + "Sky" + headerDecoration)]
    public Color colA;
    public Color colB;

    // Internal
    [HideInInspector]
    public Material material;

    // It can be used to configure render targets and their clear state. Also to create temporary render target textures.
    // When empty this render pass will render to the active camera render target.
    // You should never call CommandBuffer.SetRenderTarget. Instead call <c>ConfigureTarget</c> and <c>ConfigureClear</c>.
    // The render pipeline will ensure target setup and clearing happens in an performance manner.
    protected override void Setup(ScriptableRenderContext renderContext, CommandBuffer cmd)
    {
        //var weatherMapGen = Object.FindObjectOfType<WeatherMap> ();
        //if (Application.isPlaying) {
        //    weatherMapGen.UpdateMap ();
        //}
    }

    protected override void Execute(ScriptableRenderContext renderContext, CommandBuffer cmd, HDCamera hdCamera, CullingResults cullingResult)
    {
        // Validate inputs
        if (material == null || material.shader != shader) {
            material = new Material (shader);
        }
        numStepsLight = Mathf.Max (1, numStepsLight);

        // Noise
        var noise = Object.FindObjectOfType<NoiseGenerator> ();
        noise.UpdateNoise ();

        material.SetTexture ("NoiseTex", noise.shapeTexture);
        material.SetTexture ("DetailNoiseTex", noise.detailTexture);
        material.SetTexture ("BlueNoise", blueNoise);

        // Weathermap
        //var weatherMapGen = Object.FindObjectOfType<WeatherMap>();
        //if (!Application.isPlaying)
        //{
        //    weatherMapGen.UpdateMap();
        //}
        //material.SetTexture("WeatherMap", weatherMapGen.weatherMap);

        Vector3 size = container.localScale;
        int width = Mathf.CeilToInt (size.x);
        int height = Mathf.CeilToInt (size.y);
        int depth = Mathf.CeilToInt (size.z);

        material.SetFloat ("scale", cloudScale);
        material.SetFloat ("densityMultiplier", densityMultiplier);
        material.SetFloat ("densityOffset", densityOffset);
        material.SetFloat ("lightAbsorptionThroughCloud", lightAbsorptionThroughCloud);
        material.SetFloat ("lightAbsorptionTowardSun", lightAbsorptionTowardSun);
        material.SetFloat ("darknessThreshold", darknessThreshold);
        material.SetVector ("params", cloudTestParams);
        material.SetFloat ("rayOffsetStrength", rayOffsetStrength);

        material.SetFloat ("detailNoiseScale", detailNoiseScale);
        material.SetFloat ("detailNoiseWeight", detailNoiseWeight);
        material.SetVector ("shapeOffset", shapeOffset);
        material.SetVector ("detailOffset", detailOffset);
        material.SetVector ("detailWeights", detailNoiseWeights);
        material.SetVector("shapeNoiseWeights", shapeNoiseWeights);
        material.SetVector ("phaseParams", new Vector4 (forwardScattering, backScattering, baseBrightness, phaseFactor));

        material.SetVector ("boundsMin", container.position - container.localScale / 2);
        material.SetVector ("boundsMax", container.position + container.localScale / 2);
        material.SetInt ("numStepsLight", numStepsLight);
        material.SetVector ("mapSize", new Vector4 (width, height, depth, 0));

        material.SetFloat ("timeScale", (Application.isPlaying) ? timeScale : 0);
        material.SetFloat ("baseSpeed", baseSpeed);
        material.SetFloat ("detailSpeed", detailSpeed);

        // Set debug params
        SetDebugParams ();
        material.SetColor ("colA", colA);
        material.SetColor ("colB", colB);

        // Bind the camera color buffer along with depth without clearing the buffers.
        // Or set the a custom render target with CoreUtils.SetRenderTarget()
        SetCameraRenderTarget(cmd);
        CoreUtils.DrawFullScreen(cmd, material, shaderPassId: 0);
    }

    void SetDebugParams () {

        var noise = Object.FindObjectOfType<NoiseGenerator> ();
        //var weatherMapGen = Object.FindObjectOfType<WeatherMap> ();

        int debugModeIndex = 0;
        if (noise.viewerEnabled) {
            debugModeIndex = (noise.activeTextureType == NoiseGenerator.CloudNoiseType.Shape) ? 1 : 2;
        }
        //if (weatherMapGen.viewerEnabled) {
        //    debugModeIndex = 3;
        //}

        material.SetInt ("debugViewMode", debugModeIndex);
        material.SetFloat ("debugNoiseSliceDepth", noise.viewerSliceDepth);
        material.SetFloat ("debugTileAmount", noise.viewerTileAmount);
        material.SetFloat ("viewerSize", noise.viewerSize);
        material.SetVector ("debugChannelWeight", noise.ChannelMask);
        material.SetInt ("debugGreyscale", (noise.viewerGreyscale) ? 1 : 0);
        material.SetInt ("debugShowAllChannels", (noise.viewerShowAllChannels) ? 1 : 0);
    }

    protected override void Cleanup()
    {
        // Cleanup code
    }
}