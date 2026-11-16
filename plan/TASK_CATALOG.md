# Tiiny 2D/3D task catalog

Catalog of **100** common editor tasks. `solution` says how the task should be solved; `status` says what is verified today. `supported` tasks have a passing test reference.

## Coverage

| Status | Count |
| --- | ---: |
| supported | 40 |
| partial | 60 |
| missing | 0 |

| Solution class | Count |
| --- | ---: |
| native_macro | 30 |
| composed_primitives | 56 |
| script_behavior | 14 |
| specialized_missing | 0 |

| Dimension | Supported | Partial | Missing |
| --- | ---: | ---: | ---: |
| 2d | 15 | 35 | 0 |
| 3d | 15 | 25 | 0 |
| project | 10 | 0 | 0 |

> Behavior tasks are script work, not missing editor features. Composed tasks use `apply_editor_transaction`; supported specialized tasks have native recipes/tools.

## Tasks

### 2D sprites

| ID | Task | Solution | Status | Tools / gap |
| --- | --- | --- | --- | --- |
| 2D-001 | Create a Sprite2D from a generated image | native_macro | supported | generate_image, add_sprite_from_image |
| 2D-002 | Import an existing image as a Sprite2D | native_macro | supported | add_sprite_from_image |
| 2D-003 | Replace an existing sprite texture | composed_primitives | partial | apply_editor_transaction |
| 2D-004 | Move, rotate, or scale a node | composed_primitives | supported | apply_editor_transaction |
| 2D-005 | Add a ColorRect background | composed_primitives | partial | apply_editor_transaction |
| 2D-006 | Add a Camera2D | composed_primitives | supported | apply_editor_transaction |
| 2D-007 | Add a CanvasLayer HUD | composed_primitives | partial | apply_editor_transaction |
| 2D-008 | Add a Label with text | composed_primitives | supported | apply_editor_transaction |
| 2D-009 | Add a Button | composed_primitives | supported | apply_editor_transaction |
| 2D-010 | Add a ProgressBar | composed_primitives | partial | apply_editor_transaction |
| 2D-011 | Add a Polygon2D | composed_primitives | partial | apply_editor_transaction |
| 2D-012 | Add a Line2D path | composed_primitives | partial | apply_editor_transaction |
| 2D-013 | Add a Marker2D spawn point | composed_primitives | partial | apply_editor_transaction |
| 2D-014 | Add a TileMapLayer | native_macro | supported | add_tilemap_layer |
| 2D-015 | Add a ParallaxBackground | composed_primitives | partial | apply_editor_transaction |
| 2D-016 | Add GPUParticles2D | native_macro | supported | add_particles_2d |
| 2D-017 | Add an AnimatedSprite2D | native_macro | supported | add_animated_sprite |
| 2D-018 | Add a PointLight2D glow | composed_primitives | partial | apply_editor_transaction |
| 2D-019 | Add a CanvasModulate night tint | composed_primitives | partial | apply_editor_transaction |
| 2D-020 | Add screen shake | script_behavior | partial | read_project_file, replace_in_gdscript |

### 2D physics

| ID | Task | Solution | Status | Tools / gap |
| --- | --- | --- | --- | --- |
| 2D-021 | Add a rectangular collision shape | native_macro | supported | add_rectangular_collision_shape |
| 2D-022 | Add a StaticBody2D platform | composed_primitives | partial | apply_editor_transaction |
| 2D-023 | Add a CharacterBody2D player | composed_primitives | partial | apply_editor_transaction |
| 2D-024 | Add a RigidBody2D crate | composed_primitives | partial | apply_editor_transaction |
| 2D-025 | Add an Area2D trigger | composed_primitives | partial | apply_editor_transaction |
| 2D-026 | Create a one-way platform | composed_primitives | partial | apply_editor_transaction |
| 2D-027 | Make a surface slippery | native_macro | supported | assign_slippery_surface |
| 2D-028 | Make a surface bouncy | composed_primitives | partial | apply_editor_transaction |
| 2D-029 | Set collision layers and masks | composed_primitives | partial | apply_editor_transaction |
| 2D-030 | Add a RayCast2D | composed_primitives | partial | apply_editor_transaction |
| 2D-031 | Add a PinJoint2D | composed_primitives | partial | apply_editor_transaction |
| 2D-032 | Add a DampedSpringJoint2D | composed_primitives | partial | apply_editor_transaction |
| 2D-033 | Add a CollisionPolygon2D | composed_primitives | partial | apply_editor_transaction |
| 2D-034 | Configure mass and damping | composed_primitives | partial | apply_editor_transaction |
| 2D-035 | Detect the floor with a raycast | script_behavior | partial | read_project_file, replace_in_gdscript |

### 2D UI/audio

| ID | Task | Solution | Status | Tools / gap |
| --- | --- | --- | --- | --- |
| 2D-036 | Add a score label HUD | composed_primitives | partial | apply_editor_transaction |
| 2D-037 | Build a start menu | composed_primitives | partial | apply_editor_transaction |
| 2D-038 | Build a pause menu | composed_primitives | partial | apply_editor_transaction |
| 2D-039 | Add a health bar | composed_primitives | partial | apply_editor_transaction |
| 2D-040 | Build an inventory grid | composed_primitives | partial | apply_editor_transaction |
| 2D-041 | Add a dialogue box | composed_primitives | partial | apply_editor_transaction |
| 2D-042 | Connect a button signal | composed_primitives | supported | apply_editor_transaction |
| 2D-043 | Apply a theme and font | native_macro | supported | apply_theme |
| 2D-044 | Loop background music | native_macro | supported | configure_audio_loop |
| 2D-045 | Play a jump sound | script_behavior | partial | read_project_file, replace_in_gdscript |
| 2D-046 | Set an audio bus volume | native_macro | supported | configure_audio_bus |
| 2D-047 | Make the camera follow the player | script_behavior | partial | read_project_file, replace_in_gdscript |
| 2D-048 | Set camera limits and smoothing | composed_primitives | partial | apply_editor_transaction |
| 2D-049 | Tween a node position | script_behavior | partial | read_project_file, replace_in_gdscript |
| 2D-050 | Tween scale and rotation | script_behavior | partial | read_project_file, replace_in_gdscript |

### 3D scene

| ID | Task | Solution | Status | Tools / gap |
| --- | --- | --- | --- | --- |
| 3D-051 | Add a MeshInstance3D box | composed_primitives | supported | apply_editor_transaction |
| 3D-052 | Add a Camera3D | composed_primitives | partial | apply_editor_transaction |
| 3D-053 | Add a DirectionalLight3D | composed_primitives | partial | apply_editor_transaction |
| 3D-054 | Add a WorldEnvironment sky | composed_primitives | partial | apply_editor_transaction |
| 3D-055 | Add a CSGBox3D | composed_primitives | partial | apply_editor_transaction |
| 3D-056 | Add a GridMap | native_macro | supported | add_gridmap |
| 3D-057 | Add a StaticBody3D collision | composed_primitives | partial | apply_editor_transaction |
| 3D-058 | Add a CharacterBody3D controller | script_behavior | partial | read_project_file, replace_in_gdscript |
| 3D-059 | Add a RigidBody3D crate | composed_primitives | partial | apply_editor_transaction |
| 3D-060 | Add an Area3D trigger | composed_primitives | partial | apply_editor_transaction |
| 3D-061 | Add a NavigationRegion3D | native_macro | supported | add_navigation_region |
| 3D-062 | Add a Marker3D spawn | composed_primitives | partial | apply_editor_transaction |
| 3D-063 | Import a generated GLB model | native_macro | supported | import_generated_model |
| 3D-064 | Generate a 3D model from a reference image | native_macro | supported | append_job, get_job_status, import_generated_model |
| 3D-065 | Add collision to an imported mesh | native_macro | supported | add_mesh_collision |
| 3D-066 | Scale or rotate an imported mesh | composed_primitives | partial | apply_editor_transaction |
| 3D-067 | Add an OmniLight3D | composed_primitives | supported | apply_editor_transaction |
| 3D-068 | Add torch flicker to a 3D light | native_macro | supported | add_torch_flicker |
| 3D-069 | Add a SpotLight3D | composed_primitives | partial | apply_editor_transaction |
| 3D-070 | Add distance fog | composed_primitives | partial | apply_editor_transaction |

### 3D materials

| ID | Task | Solution | Status | Tools / gap |
| --- | --- | --- | --- | --- |
| 3D-071 | Set PBR color, metallic, and roughness | composed_primitives | supported | apply_editor_transaction |
| 3D-072 | Apply an albedo texture | composed_primitives | partial | apply_editor_transaction |
| 3D-073 | Add emission glow | composed_primitives | partial | apply_editor_transaction |
| 3D-074 | Make a material transparent | composed_primitives | partial | apply_editor_transaction |
| 3D-075 | Add a ReflectionProbe | composed_primitives | partial | apply_editor_transaction |
| 3D-087 | Import a texture as a material | composed_primitives | partial | apply_editor_transaction |

### 3D animation

| ID | Task | Solution | Status | Tools / gap |
| --- | --- | --- | --- | --- |
| 3D-076 | Animate a mesh rotation | script_behavior | partial | read_project_file, replace_in_gdscript |
| 3D-077 | Animate a door opening | script_behavior | partial | read_project_file, replace_in_gdscript |
| 3D-078 | Create an orbiting camera | script_behavior | partial | read_project_file, replace_in_gdscript |
| 3D-079 | Tween the camera | script_behavior | partial | read_project_file, replace_in_gdscript |
| 3D-080 | Play a character animation state | native_macro | supported | add_animation_tree |
| 3D-081 | Animate a skeleton | native_macro | supported | play_animation |

### 3D effects

| ID | Task | Solution | Status | Tools / gap |
| --- | --- | --- | --- | --- |
| 3D-082 | Add 3D particles | native_macro | supported | add_particles_3d |
| 3D-083 | Add a 3D trail | native_macro | supported | add_trail_3d |
| 3D-084 | Add 3D rain or snow | native_macro | supported | add_weather_3d |

### 3D audio

| ID | Task | Solution | Status | Tools / gap |
| --- | --- | --- | --- | --- |
| 3D-085 | Add positional 3D audio | composed_primitives | partial | apply_editor_transaction |

### 3D validation

| ID | Task | Solution | Status | Tools / gap |
| --- | --- | --- | --- | --- |
| 3D-086 | Validate PBR maps and topology | native_macro | supported | validate_mesh_quality |

### 3D camera

| ID | Task | Solution | Status | Tools / gap |
| --- | --- | --- | --- | --- |
| 3D-088 | Add camera collision | script_behavior | partial | read_project_file, replace_in_gdscript |

### 3D text

| ID | Task | Solution | Status | Tools / gap |
| --- | --- | --- | --- | --- |
| 3D-089 | Add 3D text | composed_primitives | partial | apply_editor_transaction |

### 3D decals

| ID | Task | Solution | Status | Tools / gap |
| --- | --- | --- | --- | --- |
| 3D-090 | Add a decal | composed_primitives | partial | apply_editor_transaction |

### Project/script

| ID | Task | Solution | Status | Tools / gap |
| --- | --- | --- | --- | --- |
| PROJECT-091 | Read and edit an existing script | script_behavior | supported | read_project_file, replace_in_gdscript, create_gdscript |
| PROJECT-092 | Create a new script | script_behavior | supported | read_project_file, replace_in_gdscript, create_gdscript |

### Project/inspect

| ID | Task | Solution | Status | Tools / gap |
| --- | --- | --- | --- | --- |
| PROJECT-093 | Inspect scene, node, and resources | native_macro | supported | get_workspace_context, get_scene_tree, inspect_node, inspect_resource |

### Debugger

| ID | Task | Solution | Status | Tools / gap |
| --- | --- | --- | --- | --- |
| PROJECT-094 | Set or remove a breakpoint | native_macro | supported | set_breakpoint, remove_breakpoint |
| PROJECT-095 | Inspect paused stack and locals | native_macro | supported | get_debugger_state, get_stack_frames, get_stack_variables, select_stack_frame |
| PROJECT-096 | Continue, step, or pause execution | native_macro | supported | debug_step, debug_continue, debug_pause |

### Jobs

| ID | Task | Solution | Status | Tools / gap |
| --- | --- | --- | --- | --- |
| PROJECT-097 | Queue and monitor a reviewed job | native_macro | supported | append_job, get_job_status |

### Assets/audio

| ID | Task | Solution | Status | Tools / gap |
| --- | --- | --- | --- | --- |
| PROJECT-098 | Generate speech and add it to the scene | native_macro | supported | append_job, get_job_status, import_generated_audio |
| PROJECT-099 | Import a WAV or OGG audio file | native_macro | supported | import_generated_audio |

### Assets/image

| ID | Task | Solution | Status | Tools / gap |
| --- | --- | --- | --- | --- |
| PROJECT-100 | Generate an image asset | native_macro | supported | generate_image |
