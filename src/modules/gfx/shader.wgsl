R"(

struct VertexInput {
    @location(0) pos: vec2<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) color: u32,
};

struct VertexOutput {
    @builtin(position) pos: vec4<f32>,
    @location(0) color: vec4<f32>,
    @location(1) uv: vec2<f32>,
};

@group(0) @binding(0) var texture_sampler: sampler;
@group(0) @binding(1) var texture_data: texture_2d<f32>;

struct SystemUniforms {
    screen_size: vec2<f32>,
};

@group(0) @binding(2) var<uniform> sys: SystemUniforms;

@vertex
fn vertex_main(input: VertexInput) -> VertexOutput {
    var output: VertexOutput;
    // Convert from screen space (0 to screen_width/screen_height) to NDC (-1 to 1)
    let screen_width = sys.screen_size.x;
    let screen_height = sys.screen_size.y;
    output.pos = vec4<f32>(
        (input.pos.x / screen_width) * 2.0 - 1.0,
        1.0 - (input.pos.y / screen_height) * 2.0,
        0.0,
        1.0
    );

    // Unpack color from u32 RGBA to vec4
    let r = f32((input.color >> 0u) & 0xFFu) / 255.0;
    let g = f32((input.color >> 8u) & 0xFFu) / 255.0;
    let b = f32((input.color >> 16u) & 0xFFu) / 255.0;
    let a = f32((input.color >> 24u) & 0xFFu) / 255.0;
    output.color = vec4<f32>(r, g, b, a);

    output.uv = input.uv;
    return output;
}

@fragment
fn fragment_main(input: VertexOutput) -> @location(0) vec4<f32> {
    // Sample texture and multiply by vertex color
    let tex_sample = textureSample(texture_data, texture_sampler, input.uv);
    return tex_sample * input.color;
}

)"
