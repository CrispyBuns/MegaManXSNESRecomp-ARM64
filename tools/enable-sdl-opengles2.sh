#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="$ROOT/snesrecomp/runner/src/desktop/host_main.c"
CMAKE="$ROOT/snesrecomp/runner/runner.cmake"
RUI_CMAKE="$ROOT/recomp-ui/recomp_ui.cmake"
RUI_SDL="$ROOT/recomp-ui/src/common/launcher_sdlcompat.h"

[[ -f "$HOST" && -f "$CMAKE" && -f "$RUI_CMAKE" && -f "$RUI_SDL" ]] || {
  echo "required submodules are missing; run: git submodule update --init --recursive" >&2
  exit 1
}

python3 - "$HOST" "$CMAKE" "$RUI_CMAKE" "$RUI_SDL" <<'PY'
from pathlib import Path
import sys

host_path, cmake_path, rui_cmake_path, rui_sdl_path = map(Path, sys.argv[1:])
host = host_path.read_text()
cmake = cmake_path.read_text()
rui_cmake = rui_cmake_path.read_text()
rui_sdl = rui_sdl_path.read_text()

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

if "if (!strcmp(id, \"opengles2\")) return \"OpenGL ES 2\";" not in host:
    host = once(
        host,
        """static const char *RendererPretty(const char *id) {
  if (!strcmp(id, "direct3d"))   return "Direct3D 9";""",
        """static const char *RendererPretty(const char *id) {
  if (!strcmp(id, "opengles2")) return "OpenGL ES 2";
  if (!strcmp(id, "direct3d"))   return "Direct3D 9";""",
        "OpenGL ES renderer display label"
    )

if "if (!strcmp(id, \"opengl\") || !strcmp(id, \"opengles\"))" not in host:
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

if "SDL_SetHintWithPriority(SDL_HINT_RENDER_DRIVER, id, SDL_HINT_OVERRIDE);" not in host:
    host = once(
        host,
        "SDL_SetHint(SDL_HINT_RENDER_DRIVER, id);",
        "SDL_SetHintWithPriority(SDL_HINT_RENDER_DRIVER, id, SDL_HINT_OVERRIDE);",
        "SDL renderer hint priority"
    )

if "SDL renderer runtime verification" not in host:
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

# Add an opt-in GLES-only mode if the vendored framework is older than the
# rg35xxh branch. Newer framework revisions already contain this option.
if "SNESRECOMP_SDL_GLES_ONLY" not in cmake:
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

# Patch recomp-ui's Dear ImGui launcher too. The launcher previously hard-linked
# OpenGL::GL, which is exactly what produced libOpenGL.so.0 even though the
# snesrecomp desktop host had already disabled its OpenGL presenter.
if "SNESRECOMP_SDL_GLES2_ONLY" not in rui_cmake:
    rui_cmake = once(
        rui_cmake,
        """    if(ANDROID)
        target_compile_definitions(${TGT} PRIVATE
            LNG_GLES2=1
            IMGUI_IMPL_OPENGL_ES2=1)
    endif()""",
        """    if(ANDROID OR SNESRECOMP_SDL_GLES2_ONLY)
        target_compile_definitions(${TGT} PRIVATE
            LNG_GLES2=1
            IMGUI_IMPL_OPENGL_ES2=1)
    endif()""",
        "recomp-ui GLES2 compile definitions"
    )

    rui_cmake = once(
        rui_cmake,
        """    if(ANDROID)
        find_library(RUI_GLES2_LIBRARY GLESv2 REQUIRED)
        find_library(RUI_EGL_LIBRARY EGL REQUIRED)
        find_library(RUI_LOG_LIBRARY log REQUIRED)
        target_link_libraries(${TGT} PRIVATE
            ${RUI_GLES2_LIBRARY} ${RUI_EGL_LIBRARY} ${RUI_LOG_LIBRARY})
    elseif(WIN32)""",
        """    if(ANDROID)
        find_library(RUI_GLES2_LIBRARY GLESv2 REQUIRED)
        find_library(RUI_EGL_LIBRARY EGL REQUIRED)
        find_library(RUI_LOG_LIBRARY log REQUIRED)
        target_link_libraries(${TGT} PRIVATE
            ${RUI_GLES2_LIBRARY} ${RUI_EGL_LIBRARY} ${RUI_LOG_LIBRARY})
    elseif(SNESRECOMP_SDL_GLES2_ONLY)
        find_library(RUI_GLES2_LIBRARY GLESv2 REQUIRED)
        find_library(RUI_EGL_LIBRARY EGL REQUIRED)
        target_link_libraries(${TGT} PRIVATE
            ${RUI_GLES2_LIBRARY} ${RUI_EGL_LIBRARY} ${CMAKE_DL_LIBS})
        message(STATUS "recomp-ui: SDL2 OpenGL ES 2 backend; desktop OpenGL disabled")
    elseif(WIN32)""",
        "recomp-ui GLES2 link libraries"
    )

# SDL2's compatibility header must expose GLES2 headers to both launcher_gl.c
# and the ImGui SDL2/OpenGL backend. This avoids pulling SDL_opengl.h.
if "defined(LNG_GLES2)" not in rui_sdl:
    rui_sdl = once(
        rui_sdl,
        """#if !defined(LNG_SDL3)
// ---- map SDL3 spellings onto SDL2 -----------------------------------------

// GL header (Android uses GLES; desktop SDL2 uses the system OpenGL header).
#if defined(__ANDROID__)
#include <SDL_opengles2.h>
#else
#include <SDL_opengl.h>
#endif""",
        """#if !defined(LNG_SDL3)
// ---- map SDL3 spellings onto SDL2 -----------------------------------------

// GLES2 handheld builds must never include SDL_opengl.h: doing so can make
// the launcher compile/link against desktop GL even though the game host is
// otherwise GLES-only.
#if defined(__ANDROID__) || defined(LNG_GLES2)
#include <SDL_opengles2.h>
#else
#include <SDL_opengl.h>
#endif""",
        "SDL2 GLES2 GL header selection"
    )

    rui_sdl = once(
        rui_sdl,
        """#else
// ---- native SDL3 ----------------------------------------------------------
#include <SDL3/SDL_opengl.h>""",
        """#else
// ---- native SDL3 ----------------------------------------------------------
#if defined(LNG_GLES2)
#include <SDL3/SDL_opengles2.h>
#else
#include <SDL3/SDL_opengl.h>
#endif""",
        "SDL3 GLES2 GL header selection"
    )

host_path.write_text(host)
cmake_path.write_text(cmake)
rui_cmake_path.write_text(rui_cmake)
rui_sdl_path.write_text(rui_sdl)
print("SDL2/GLES2-only host + recomp-ui patch applied.")
print("Configure with: -DSNESRECOMP_SDL_BACKEND=SDL2 -DSNESRECOMP_SDL_GLES2_ONLY=ON")
PY

echo "SDL2 GLES2-only host + recomp-ui patch applied."
echo "Configure with: -DSNESRECOMP_SDL_BACKEND=SDL2 -DSNESRECOMP_SDL_GLES2_ONLY=ON"