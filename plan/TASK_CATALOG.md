# Tiiny 2D/3D task catalog

Catalog of **100** common editor tasks with current native-tool status. `supported` means the required tool exists and has a test reference; `partial` means a fallback or incomplete path exists; `missing` means no dedicated tool.

## Coverage

| Status | Count |
| --- | ---: |
| supported | 17 |
| partial | 12 |
| missing | 71 |

| Dimension | Supported | Partial | Missing |
| --- | ---: | ---: | ---: |
| 2d | 4 | 7 | 39 |
| 3d | 3 | 5 | 32 |
| project | 10 | 0 | 0 |

## Tasks

### 2D sprites

| ID | Task | Status | Tools / gap |
| --- | --- | --- | --- |
| 2D-001 | Create a Sprite2D from a generated image | supported | generate_image, add_sprite_from_image |
| 2D-002 | Import an existing image as a Sprite2D | supported | add_sprite_from_image |
| 2D-003 | Replace an existing sprite texture | partial | read_project_file, replace_in_gdscript |
| 2D-004 | Move, rotate, or scale a node | partial | inspect_node, read_project_file, replace_in_gdscript |
| 2D-005 | Add a ColorRect background | missing | No generic Control creation recipe. |
| 2D-006 | Add a Camera2D | missing | No generic node creation or camera configuration tool. |
| 2D-007 | Add a CanvasLayer HUD | missing | No generic node creation tool. |
| 2D-008 | Add a Label with text | missing | No UI node creation tool. |
| 2D-009 | Add a Button | missing | No UI node creation tool. |
| 2D-010 | Add a ProgressBar | missing | No UI node creation tool. |
| 2D-011 | Add a Polygon2D | missing | No polygon node creation tool. |
| 2D-012 | Add a Line2D path | missing | No Line2D creation tool. |
| 2D-013 | Add a Marker2D spawn point | missing | No generic node creation tool. |
| 2D-014 | Add a TileMapLayer | missing | No TileMap creation/tileset tool. |
| 2D-015 | Add a ParallaxBackground | missing | No parallax node creation tool. |
| 2D-016 | Add GPUParticles2D | missing | No particle creation tool. |
| 2D-017 | Add an AnimatedSprite2D | missing | No SpriteFrames/animated sprite tool. |
| 2D-018 | Add a PointLight2D glow | missing | Torch flicker requires an existing light; no light creation tool. |
| 2D-019 | Add a CanvasModulate night tint | missing | No CanvasModulate creation tool. |
| 2D-020 | Add screen shake | missing | No camera or tween creation tool. |

### 2D physics

| ID | Task | Status | Tools / gap |
| --- | --- | --- | --- |
| 2D-021 | Add a rectangular collision shape | supported | add_rectangular_collision_shape |
| 2D-022 | Add a StaticBody2D platform | missing | No generic physics body creation tool. |
| 2D-023 | Add a CharacterBody2D player | missing | No generic body creation tool. |
| 2D-024 | Add a RigidBody2D crate | missing | No generic body creation tool. |
| 2D-025 | Add an Area2D trigger | missing | No Area2D creation tool. |
| 2D-026 | Create a one-way platform | missing | No collision one-way configuration recipe. |
| 2D-027 | Make a surface slippery | supported | assign_slippery_surface |
| 2D-028 | Make a surface bouncy | partial | assign_slippery_surface |
| 2D-029 | Set collision layers and masks | missing | No collision layer/mask mutation tool. |
| 2D-030 | Add a RayCast2D | missing | No RayCast2D creation tool. |
| 2D-031 | Add a PinJoint2D | missing | No joint creation tool. |
| 2D-032 | Add a DampedSpringJoint2D | missing | No joint creation tool. |
| 2D-033 | Add a CollisionPolygon2D | missing | Only rectangle collision shapes are supported. |
| 2D-034 | Configure mass and damping | missing | No generic RigidBody property mutation tool. |
| 2D-035 | Detect the floor with a raycast | partial | read_project_file, replace_in_gdscript |

### 2D UI/audio

| ID | Task | Status | Tools / gap |
| --- | --- | --- | --- |
| 2D-036 | Add a score label HUD | missing | No UI node creation tool. |
| 2D-037 | Build a start menu | missing | No UI composition tool. |
| 2D-038 | Build a pause menu | missing | No UI or input tool. |
| 2D-039 | Add a health bar | missing | No UI node creation tool. |
| 2D-040 | Build an inventory grid | missing | No UI composition tool. |
| 2D-041 | Add a dialogue box | missing | No UI composition tool. |
| 2D-042 | Connect a button signal | partial | read_project_file, replace_in_gdscript |
| 2D-043 | Apply a theme and font | missing | No theme/font mutation tool. |
| 2D-044 | Loop background music | partial | import_generated_audio |
| 2D-045 | Play a jump sound | partial | import_generated_audio, read_project_file, replace_in_gdscript |
| 2D-046 | Set an audio bus volume | missing | No AudioServer/bus mutation tool. |
| 2D-047 | Make the camera follow the player | missing | No Camera2D creation or follow tool. |
| 2D-048 | Set camera limits and smoothing | missing | No Camera2D property mutation tool. |
| 2D-049 | Tween a node position | missing | No tween creation tool. |
| 2D-050 | Tween scale and rotation | missing | No tween/animation creation tool. |

### 3D scene

| ID | Task | Status | Tools / gap |
| --- | --- | --- | --- |
| 3D-051 | Add a MeshInstance3D box | missing | No generic 3D node creation tool. |
| 3D-052 | Add a Camera3D | missing | No Camera3D creation tool. |
| 3D-053 | Add a DirectionalLight3D | missing | No light creation tool. |
| 3D-054 | Add a WorldEnvironment sky | missing | No environment creation tool. |
| 3D-055 | Add a CSGBox3D | missing | No CSG creation tool. |
| 3D-056 | Add a GridMap | missing | No GridMap tool. |
| 3D-057 | Add a StaticBody3D collision | missing | No 3D collision creation tool. |
| 3D-058 | Add a CharacterBody3D controller | missing | No 3D body/controller creation tool. |
| 3D-059 | Add a RigidBody3D crate | missing | No 3D body creation tool. |
| 3D-060 | Add an Area3D trigger | missing | No Area3D creation tool. |
| 3D-061 | Add a NavigationRegion3D | missing | No navigation tool. |
| 3D-062 | Add a Marker3D spawn | missing | No generic 3D node creation tool. |
| 3D-063 | Import a generated GLB model | supported | import_generated_model |
| 3D-064 | Generate a 3D model from a reference image | supported | append_job, get_job_status, import_generated_model |
| 3D-065 | Add collision to an imported mesh | missing | No mesh-to-collision generation tool. |
| 3D-066 | Scale or rotate an imported mesh | partial | read_project_file, replace_in_gdscript |
| 3D-067 | Add an OmniLight3D | missing | Torch flicker requires an existing light; no light creation tool. |
| 3D-068 | Add torch flicker to a 3D light | supported | add_torch_flicker |
| 3D-069 | Add a SpotLight3D | missing | No light creation tool. |
| 3D-070 | Add distance fog | missing | No environment/fog tool. |

### 3D materials

| ID | Task | Status | Tools / gap |
| --- | --- | --- | --- |
| 3D-071 | Set PBR color, metallic, and roughness | missing | No material creation/property tool. |
| 3D-072 | Apply an albedo texture | missing | No material/texture assignment tool. |
| 3D-073 | Add emission glow | missing | No material emission tool. |
| 3D-074 | Make a material transparent | missing | No material transparency tool. |
| 3D-075 | Add a ReflectionProbe | missing | No reflection probe tool. |
| 3D-087 | Import a texture as a material | missing | No material creation tool. |

### 3D animation

| ID | Task | Status | Tools / gap |
| --- | --- | --- | --- |
| 3D-076 | Animate a mesh rotation | partial | read_project_file, replace_in_gdscript |
| 3D-077 | Animate a door opening | partial | read_project_file, replace_in_gdscript |
| 3D-078 | Create an orbiting camera | missing | No Camera3D/script animation tool. |
| 3D-079 | Tween the camera | missing | No tween creation tool. |
| 3D-080 | Play a character animation state | missing | No AnimationTree/state machine tool. |
| 3D-081 | Animate a skeleton | missing | No skeleton/animation tool. |

### 3D effects

| ID | Task | Status | Tools / gap |
| --- | --- | --- | --- |
| 3D-082 | Add 3D particles | missing | No 3D particle creation tool. |
| 3D-083 | Add a 3D trail | missing | No 3D trail/particle tool. |
| 3D-084 | Add 3D rain or snow | missing | No 3D weather/particle tool. |

### 3D audio

| ID | Task | Status | Tools / gap |
| --- | --- | --- | --- |
| 3D-085 | Add positional 3D audio | partial | import_generated_audio |

### 3D validation

| ID | Task | Status | Tools / gap |
| --- | --- | --- | --- |
| 3D-086 | Validate PBR maps and topology | partial | import_generated_model |

### 3D camera

| ID | Task | Status | Tools / gap |
| --- | --- | --- | --- |
| 3D-088 | Add camera collision | missing | No Camera3D configuration tool. |

### 3D text

| ID | Task | Status | Tools / gap |
| --- | --- | --- | --- |
| 3D-089 | Add 3D text | missing | No 3D text creation tool. |

### 3D decals

| ID | Task | Status | Tools / gap |
| --- | --- | --- | --- |
| 3D-090 | Add a decal | missing | No decal creation tool. |

### Project/script

| ID | Task | Status | Tools / gap |
| --- | --- | --- | --- |
| PROJECT-091 | Read and edit an existing script | supported | read_project_file, replace_in_gdscript |
| PROJECT-092 | Create a new script | supported | create_gdscript |

### Project/inspect

| ID | Task | Status | Tools / gap |
| --- | --- | --- | --- |
| PROJECT-093 | Inspect scene, node, and resources | supported | get_workspace_context, get_scene_tree, inspect_node, inspect_resource |

### Debugger

| ID | Task | Status | Tools / gap |
| --- | --- | --- | --- |
| PROJECT-094 | Set or remove a breakpoint | supported | set_breakpoint, remove_breakpoint |
| PROJECT-095 | Inspect paused stack and locals | supported | get_debugger_state, get_stack_frames, get_stack_variables, select_stack_frame |
| PROJECT-096 | Continue, step, or pause execution | supported | debug_step, debug_continue, debug_pause |

### Jobs

| ID | Task | Status | Tools / gap |
| --- | --- | --- | --- |
| PROJECT-097 | Queue and monitor a reviewed job | supported | append_job, get_job_status |

### Assets/audio

| ID | Task | Status | Tools / gap |
| --- | --- | --- | --- |
| PROJECT-098 | Generate speech and add it to the scene | supported | append_job, get_job_status, import_generated_audio |
| PROJECT-099 | Import a WAV or OGG audio file | supported | import_generated_audio |

### Assets/image

| ID | Task | Status | Tools / gap |
| --- | --- | --- | --- |
| PROJECT-100 | Generate an image asset | supported | generate_image |
