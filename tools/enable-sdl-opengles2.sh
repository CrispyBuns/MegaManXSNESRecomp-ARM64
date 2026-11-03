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
        raise SystemExit(
            f"Expected exactly one {label} block, found {count}; refusing a partial patch."
        )
    return source.replace(old, new, 1)

# The framework owns the actual game presenter. Refuse to continue unless its
# ARM64 host is already strict GLES2-only and cannot add the desktop GL host.
required_framework = (
    "option(SNESRECOMP_SDL_GLES2_ONLY",
    "if(NOT ANDROID AND NOT SNESRECOMP_SDL_GLES2_ONLY)",
)
for marker in required_framework:
    if marker not in cmake:
        raise SystemExit(
            "The snesrecomp submodule is missing its strict SDL2/GLES2-only "
            "support. Update the snesrecomp submodule to CrispyBuns/snesrecomp "
            "branch rg35xxh before building."
        )
if "#if SNESRECOMP_SDL_GLES2_ONLY" not in host:
    raise SystemExit("The snesrecomp host does not contain its strict GLES2 renderer path.")
if "snesrecomp_sdl_create_renderer_named" not in host or \
   'strcmp(selected_driver, "opengles2")' not in host:
    raise SystemExit("The snesrecomp host does not enforce SDL's opengles2 renderer at runtime.")

# recomp-ui is a separate build component. Its ImGui OpenGL3 backend must be
# compiled in GLES2 mode, and its link branch must use GLESv2/EGL rather than
# recomp_resolve_gl()/OpenGL::GL.
if "if(ANDROID OR SNESRECOMP_SDL_GLES2_ONLY)" not in rui_cmake:
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
        "recomp-ui GLES2 compile definitions",
    )

if "elseif(SNESRECOMP_SDL_GLES2_ONLY)" not in rui_cmake:
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
        "recomp-ui GLES2 link libraries",
    )

# SDL's compatibility layer supplies the GL header used by ImGui's backend.
# It must select SDL2 GLES2 headers, never SDL_opengl.h, for this target.
if "#if defined(__ANDROID__) || defined(LNG_GLES2)" not in rui_sdl:
    rui_sdl = once(
        rui_sdl,
        """#if defined(__ANDROID__)
#include <SDL_opengles2.h>
#else
#include <SDL_opengl.h>
#endif""",
        """#if defined(__ANDROID__) || defined(LNG_GLES2)
#include <SDL_opengles2.h>
#else
#include <SDL_opengl.h>
#endif""",
        "SDL2 GLES2 GL header selection",
    )

if "#if defined(LNG_GLES2)" not in rui_sdl:
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
        "SDL3 GLES2 GL header selection",
    )

# Post-patch assertions make this helper safe to run on every clean CI build.
assert "if(ANDROID OR SNESRECOMP_SDL_GLES2_ONLY)" in rui_cmake
assert "elseif(SNESRECOMP_SDL_GLES2_ONLY)" in rui_cmake
assert "defined(LNG_GLES2)" in rui_sdl
assert "recomp_resolve_gl(RUI_GL_TARGET)" in rui_cmake  # retained only for desktop targets

rui_cmake_path.write_text(rui_cmake)
rui_sdl_path.write_text(rui_sdl)
print("Verified snesrecomp strict GLES2 host and patched recomp-ui for GLES2.")
PY

echo "SDL2/GLES2-only host and launcher configuration verified."
echo "Expected CMake option: -DSNESRECOMP_SDL_GLES2_ONLY=ON"
