struct CubeParams {
  face: f32,
  mode: f32,
  _pad0: f32,
  _pad1: f32,
  // Linear-space tints for the 6 studio spots. Populated from EVE_AGENT_BLUE
  // and EVE_AGENT_SPOT_TINTS in render.ts during the one-time colored bake.
  spotTints: array<vec4f, 6>,
};

struct VertexOutput {
  @builtin(position) clipPosition: vec4f,
  @location(0) uv: vec2f,
};

@group(0) @binding(0) var<uniform> params: CubeParams;

@vertex
fn vs_main(@builtin(vertex_index) vertexIndex: u32) -> VertexOutput {
  let xy = array<vec2f, 3>(
    vec2f(-1.0, -1.0),
    vec2f(3.0, -1.0),
    vec2f(-1.0, 3.0),
  );
  let p = xy[vertexIndex];
  var output: VertexOutput;
  output.clipPosition = vec4f(p, 0.0, 1.0);
  // The rasterizer writes clip-top (p.y = +1) to texel row 0, but cube_dir/cube_lookup_uv_face
  // treat uv.y as texture-v growing DOWNWARD (p.y = 2v-1). Without flipping v here, the baked
  // face is stored vertically mirrored relative to how the sampler reads it, which inverts +Y
  // and disagrees with the /cube-camera rasterized capture. Flip v so bake matches read.
  output.uv = vec2f(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
  return output;
}

fn cube_dir(face: f32, uv: vec2f) -> vec3f {
  let p = uv * 2.0 - vec2f(1.0);
  // WebGPU cube face order: +X, -X, +Y, -Y, +Z, -Z.
  if (face < 0.5) {
    return normalize(vec3f(1.0, -p.y, -p.x));
  }
  if (face < 1.5) {
    return normalize(vec3f(-1.0, -p.y, p.x));
  }
  if (face < 2.5) {
    return normalize(vec3f(p.x, 1.0, p.y));
  }
  if (face < 3.5) {
    return normalize(vec3f(p.x, -1.0, -p.y));
  }
  if (face < 4.5) {
    return normalize(vec3f(p.x, -p.y, 1.0));
  }
  return normalize(vec3f(-p.x, -p.y, -1.0));
}

fn spot(dir: vec3f, center: vec3f, radius: f32, softness: f32, luminance: f32) -> vec3f {
  let d = distance(normalize(dir), normalize(center));
  let soft = clamp(softness, 0.0, 1.0);
  // Gaussian softboxes keep an HDR tail instead of clamping to exact zero at radius.
  // This avoids content-driven hard cuts in reflected highlights when only one or two
  // manually edited lights are enabled. Radius still controls apparent card size;
  // softness widens/narrows the falloff without changing the desaturated white color.
  let sigma = max(radius * mix(0.35, 0.85, soft), 0.001);
  let t = exp(-0.5 * (d / sigma) * (d / sigma));
  // White, desaturated studio softboxes. Units are scene-linear relative cd/m^2-ish values.
  return vec3f(1.0) * (t * luminance);
}

fn spot_tinted(index: u32, dir: vec3f, center: vec3f, radius: f32, softness: f32, luminance: f32) -> vec3f {
  let tint = select(vec3f(1.0), params.spotTints[index].rgb, params.mode > 0.5);
  return spot(dir, center, radius, softness, luminance) * tint;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4f {
  let dir = cube_dir(params.face, input.uv);

  // Dim black studio with high-dynamic-range white cards/softboxes.
  var radiance = vec3f(0.0);

  // Spot index -> tint is controlled by EVE_AGENT_SPOT_TINTS in render.ts.
  // Current design: all spots are shades of blue mixed toward white.
  // dir center radius softness luminance
  radiance += spot_tinted(0u, dir, vec3f(-1.4, 2., -0.4), 0.3, 0.02, 10.0); // top-left high
  radiance += spot_tinted(1u, dir, vec3f(-0.4, 1., 1.), 0.9, 0.02, 1.0); // front-left high

  radiance += spot_tinted(2u, dir, vec3f(0.5, 0., 1.)*10., 0.5, 0.1, 0.2); // front-right
  radiance += spot_tinted(3u, dir, vec3f(0.4, -0.3, -1.), 0.1, 1., 0.5); // back-right

  radiance += spot_tinted(4u, dir, vec3f(1.0, -2., -0.5), 0.2, 1., 5.); // front-bottom-right
  radiance += spot_tinted(5u, dir, vec3f(-0.3, -0.2, -0.2), 0.3, 4., 3.); // front-bottom-left

  return vec4f(radiance, 1.0);
}
