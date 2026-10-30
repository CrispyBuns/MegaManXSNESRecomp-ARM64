#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="$ROOT/snesrecomp/runner/src/desktop/host_main.c"
CMAKE="$ROOT/snesrecomp/runner/runner.cmake"

[[ -f "$HOST" && -f "$CMAKE" ]] || {
  echo "snesrecomp submodule is missing; run: git submodule update --init --recursive" >&2
  exit 1
}

python3 - "$HOST" "$CMAKE" <<'PY'
from pathlib import Path
import sys

host_path, cmake_path = map(Path, sys.argv[1:])
host = host_path.read_text()
cmake = cmake_path.read_text()

if "requested opengles2" in host and "SNESRECOMP_SDL_GLES_ONLY" in cmake:
    print("SDL GLES2 host patch is already applied.")
    raise SystemExit(0)

def once(source, old, new, label):
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"Expected exactly one {label} block, found {count}; refusing a partial patch.")
    return source.replace(old, new, 1)

# The GLES-only build must not compile or reference the desktop GL 3.1 presenter.
host = host.replace(
    "#ifndef __ANDROID__",
    "#if !defined(__ANDROID__) && !defined(SNESRECOMP_SDL_GLES_ONLY)"
)

host = once(
    host,
    """static const char *RendererPretty(const char *id) {
  if (!strcmp(id, "direct3d"))   return "Direct3D 9";""",
    """static const char *RendererPretty(const char *id) {
  if (!strcmp(id, "opengles2")) return "OpenGL ES 2";
  if (!strcmp(id, "direct3d"))   return "Direct3D 9";""",
    "OpenGL ES renderer display label"
)

host = once(
    host,
    """    /* opengles2 reaches the same hardware as OpenGL through a smaller API;
     * SDL's opengl driver is the native presenter's twin. Neither is a
     * choice a player should be offered. */
    if (!strcmp(id, "opengl") || !strcmp(id, "opengles2") || !strcmp(id, "opengles"))
      continue;""",
    """    /* The desktop OpenGL presenter is separate. Keep SDL's GLES2 driver
     * selectable for embedded Linux targets; opengles (GLES1) is not suitable. */
    if (!strcmp(id, "opengl") || !strcmp(id, "opengles"))
      continue;""",
    "SDL renderer enumeration"
)

host = once(
    host,
    "SDL_SetHint(SDL_HINT_RENDER_DRIVER, id);",
    "SDL_SetHintWithPriority(SDL_HINT_RENDER_DRIVER, id, SDL_HINT_OVERRIDE);",
    "SDL renderer hint priority"
)

host = once(
    host,
    """  g_renderer = renderer;

  g_texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING,""",
    """  const char *actual_renderer = snesrecomp_sdl_renderer_name(renderer);
  printf("[video] SDL renderer created: %s\\n",
         actual_renderer ? actual_renderer : "(unknown)");
  if (!strcmp(g_config.renderer, "opengles2") &&
      (!actual_renderer || strcmp(actual_renderer, "opengles2"))) {
    fprintf(stderr, "[video] ERROR: requested opengles2, but SDL created %s\\n",
            actual_renderer ? actual_renderer : "(unknown)");
    SDL_DestroyRenderer(renderer);
    return false;
  }
  g_renderer = renderer;

  g_texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING,""",
    "SDL renderer runtime verification"
)

# Add an opt-in GLES-only mode that omits the desktop GL 3.1 presenter and
# defines the matching host-side guards.
cmake = once(
    cmake,
    """function(snesrecomp_target_desktop_host target)
    set(options TIER2)""",
    """option(SNESRECOMP_SDL_GLES_ONLY
    "Use SDL's OpenGL ES renderer only; omit the desktop OpenGL 3.1 presenter"
    OFF)

function(snesrecomp_target_desktop_host target)
    set(options TIER2)""",
    "GLES-only CMake option"
)

cmake = once(
    cmake,
    """    if(NOT ANDROID)
        snesrecomp_target_opengl(${target})
    endif()""",
    """    if(NOT ANDROID AND NOT SNESRECOMP_SDL_GLES_ONLY)
        snesrecomp_target_opengl(${target})
    elseif(SNESRECOMP_SDL_GLES_ONLY)
        target_compile_definitions(${target} PRIVATE SNESRECOMP_SDL_GLES_ONLY=1)
        message(STATUS "${target}: SDL GLES-only host; desktop OpenGL presenter disabled")
    endif()""",
    "desktop OpenGL presenter condition"
)

host_path.write_text(host)
cmake_path.write_text(cmake)
print(f"Patched {host_path}")
print(f"Patched {cmake_path}")
PY

echo "SDL GLES2 host patch applied."
echo "Configure with: -DSNESRECOMP_SDL_BACKEND=SDL2 -DSNESRECOMP_SDL_GLES_ONLY=ON"
