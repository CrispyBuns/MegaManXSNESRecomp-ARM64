#!/usr/bin/env bash
# build-linux-dev.sh - configure and build a local Linux tree (build-linux/).
#
# The development counterpart to tools/build-linux.sh, which packages release
# AppImages. This script checks the toolchain, submodules, SDL and generated
# code before configuring, so a missing piece fails with a fix, not a CMake
# trace. It reuses an existing build directory and only reconfigures when
# something that matters changed.
#
# Usage:
#   bash tools/build-linux-dev.sh [options] [-- extra cmake args]
#
# Common:
#   (no options)          Release build of MegaManXSNESRecomp in build-linux/
#   --rom PATH            stage a USA ROM as ./mmx.sfc (verified), then build
#   --regen               regenerate src/gen from ./mmx.sfc before building
#                         (automatic when src/gen is missing or out of date)
#   --no-regen            never regenerate automatically; only warn
#   --setup-host          ROM-free build (no generated code), as CI does
#   --tests               also build and run the unit tests (ctest)
#   --run [ARGS...]       launch the game after building (must be last)
#
# Build options:
#   --type TYPE           Release (default), RelWithDebInfo or Debug
#   --build-dir DIR       build directory (default: build-linux)
#   --target NAME         CMake target (default: MegaManXSNESRecomp); repeatable
#   --all                 every target, including Rockman X when generated
#   --sdl auto|SDL3|SDL2  SDL backend (default: auto, SDL3 preferred)
#   --generator G         ninja or make (default: ninja when installed)
#   --jobs N              parallel jobs (default: nproc)
#   --trace               compile the developer trace/debug server in
#   --version V           build stamp (default: exact git tag, else "dev")
#
# Maintenance:
#   --fresh               delete the CMake cache and reconfigure
#   --clean               delete the whole build directory first
#   --bootstrap           initialize/repair submodules (tools/bootstrap.sh)
#   --libjuice-dir DIR    use a local libjuice checkout instead of downloading
#   --offline             never download dependencies (needs --libjuice-dir)
#   --verbose             show full compiler command lines
#   -h, --help            this text
#
# Environment: CC, CXX, CMAKE, PYTHON and SNESRECOMP_ANALYSIS_BACKEND
# (native|python, for --regen) are honoured.
#
# Debian/Ubuntu packages: build-essential cmake ninja-build python3 git
#   libsdl3-dev (or libsdl2-dev with --sdl SDL2) libgl1-mesa-dev pkg-config
# --regen additionally needs Rust (rustup.rs) unless
#   SNESRECOMP_ANALYSIS_BACKEND=python.
set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USA_ROM_SHA=b8f70a6e7fb93819f79693578887e2c11e196bdf1ac6ddc7cb924b1ad0be2d32
CI_TESTS=(mmx_display_test mmx_wide_policy_test mmx_renderer_test
          mmx_password_save_test mmx_zero_test)

# ------------------------------------------------------------------ output --
if [ -t 1 ]; then BOLD=$'\e[1m'; RED=$'\e[31m'; YEL=$'\e[33m'; GRN=$'\e[32m'; RST=$'\e[0m'
else BOLD=""; RED=""; YEL=""; GRN=""; RST=""; fi
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RST"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%swarning:%s %s\n' "$YEL" "$RST" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$RED" "$RST" "$1" >&2; shift
         for line in "$@"; do printf '       %s\n' "$line" >&2; done; exit 1; }
on_error() {
  local code=$? line=$1 cmd=$2
  printf '%serror:%s "%s" failed (exit %d, %s line %d)\n' \
      "$RED" "$RST" "$cmd" "$code" "$(basename "$0")" "$line" >&2
  exit "$code"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
usage() { sed -n '2,/^set -Eeuo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# ------------------------------------------------------------------- args --
BUILD_TYPE=Release
BUILD_DIR=build-linux-prod
TARGETS=()
ALL=0
SDL_CHOICE=auto
GENERATOR=""
JOBS="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
TRACE=0
VERSION=""
ROM_SRC=""
REGEN=0
NO_REGEN=0
SETUP_HOST=0
TESTS=0
RUN=0
RUN_ARGS=()
FRESH=0
CLEAN=0
BOOTSTRAP=0
LIBJUICE_DIR=""
OFFLINE=0
VERBOSE=0
EXTRA_CMAKE=()

need_value() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value (see --help)"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --type) need_value "$@"; BUILD_TYPE="$2"; shift 2 ;;
    --build-dir) need_value "$@"; BUILD_DIR="$2"; shift 2 ;;
    --target) need_value "$@"; TARGETS+=("$2"); shift 2 ;;
    --all) ALL=1; shift ;;
    --sdl) need_value "$@"; SDL_CHOICE="$2"; shift 2 ;;
    --generator) need_value "$@"; GENERATOR="$2"; shift 2 ;;
    --jobs|-j) need_value "$@"; JOBS="$2"; shift 2 ;;
    --trace) TRACE=1; shift ;;
    --version) need_value "$@"; VERSION="$2"; shift 2 ;;
    --rom) need_value "$@"; ROM_SRC="$2"; shift 2 ;;
    --regen) REGEN=1; shift ;;
    --no-regen) NO_REGEN=1; shift ;;
    --setup-host) SETUP_HOST=1; shift ;;
    --tests) TESTS=1; shift ;;
    --run) RUN=1; shift; RUN_ARGS=("$@"); break ;;
    --fresh) FRESH=1; shift ;;
    --clean) CLEAN=1; shift ;;
    --bootstrap) BOOTSTRAP=1; shift ;;
    --libjuice-dir) need_value "$@"; LIBJUICE_DIR="$2"; shift 2 ;;
    --offline) OFFLINE=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; EXTRA_CMAKE=("$@"); break ;;
    *) die "unknown option: $1" "Run with --help for the list of options." ;;
  esac
done

case "$BUILD_TYPE" in
  Release|RelWithDebInfo|Debug|MinSizeRel) ;;
  release) BUILD_TYPE=Release ;; relwithdebinfo) BUILD_TYPE=RelWithDebInfo ;;
  debug) BUILD_TYPE=Debug ;;
  *) die "--type must be Release, RelWithDebInfo or Debug (got '$BUILD_TYPE')" ;;
esac
case "$SDL_CHOICE" in auto|SDL3|SDL2) ;; sdl3) SDL_CHOICE=SDL3 ;; sdl2) SDL_CHOICE=SDL2 ;;
  *) die "--sdl must be auto, SDL3 or SDL2 (got '$SDL_CHOICE')" ;; esac
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive number (got '$JOBS')"
[ "$REGEN" = 1 ] && [ "$SETUP_HOST" = 1 ] && die "--regen and --setup-host cannot be combined"
[ "$REGEN" = 1 ] && [ "$NO_REGEN" = 1 ] && die "--regen and --no-regen cannot be combined"
[ -n "$ROM_SRC" ] && [ "$SETUP_HOST" = 1 ] && die "--rom and --setup-host cannot be combined"
[ "$OFFLINE" = 1 ] && [ -z "$LIBJUICE_DIR" ] &&
  die "--offline needs --libjuice-dir (git clone -b v1.7.2 https://github.com/paullouisageneau/libjuice)"
case "$BUILD_DIR" in /*) ;; *) BUILD_DIR="$REPO/$BUILD_DIR" ;; esac
[ "$BUILD_DIR" != "$REPO" ] && [ "$BUILD_DIR" != "/" ] || die "refusing to use $BUILD_DIR as the build directory"

cd "$REPO"

# -------------------------------------------------------------- toolchain --
step "Checking toolchain"
CMAKE="${CMAKE:-cmake}"
command -v "$CMAKE" >/dev/null || die "cmake not found" "Install it: sudo apt install cmake"
cmake_version="$("$CMAKE" --version | awk 'NR==1 {print $3}')"
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }
version_ge "$cmake_version" 3.20 || die "CMake $cmake_version is too old; 3.20 or newer is required"
info "cmake $cmake_version"

PYTHON="${PYTHON:-$(command -v python3 || command -v python || true)}"
[ -n "$PYTHON" ] || die "python3 not found" "Install it: sudo apt install python3"
"$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 9))' ||
  die "$("$PYTHON" --version 2>&1) is too old; Python 3.9 or newer is required"
info "$("$PYTHON" --version 2>&1)"

cc="${CC:-$(command -v cc || command -v gcc || command -v clang || true)}"
cxx="${CXX:-$(command -v c++ || command -v g++ || command -v clang++ || true)}"
[ -n "$cc" ] && [ -n "$cxx" ] || die "no C/C++ compiler found" "Install one: sudo apt install build-essential"
info "C: $cc   C++: $cxx"
command -v git >/dev/null || die "git not found" "Install it: sudo apt install git"

if [ -z "$GENERATOR" ]; then
  if command -v ninja >/dev/null; then GENERATOR=ninja; else GENERATOR="make"
    warn "ninja not found; using make (sudo apt install ninja-build is faster)"; fi
fi
case "$GENERATOR" in
  ninja|Ninja) command -v ninja >/dev/null || die "ninja not found" "Install it: sudo apt install ninja-build"
               CMAKE_GENERATOR="Ninja" ;;
  make|Make|"Unix Makefiles") command -v make >/dev/null || die "make not found"
               CMAKE_GENERATOR="Unix Makefiles" ;;
  *) die "--generator must be ninja or make (got '$GENERATOR')" ;;
esac
info "generator: $CMAKE_GENERATOR, $JOBS jobs"

# ------------------------------------------------------------- submodules --
step "Checking submodules"
submodules_ok() {
  [ -f snesrecomp/runner/runner.cmake ] && [ -f recomp-ui/recomp_ui.cmake ] &&
  [ -f snesrecomp/lib/recomp-net/CMakeLists.txt ] &&
  ! git submodule status --recursive 2>/dev/null | grep -q '^[-U]'
}
if [ "$BOOTSTRAP" = 1 ] || ! submodules_ok; then
  [ "$BOOTSTRAP" = 1 ] || info "submodules are missing or incomplete; initializing"
  bash tools/bootstrap.sh
fi
submodules_ok || die "submodules are still incomplete" "Run: bash tools/bootstrap.sh"
if git submodule status --recursive | grep -q '^+'; then
  warn "a submodule is checked out at a different commit than this repo pins:"
  git submodule status --recursive | grep '^+' | sed 's/^/         /' >&2
fi
info "snesrecomp $(git -C snesrecomp rev-parse --short HEAD)"

# -------------------------------------------------------------------- SDL --
step "Checking SDL renderer dependencies"
sdl_found() { # backend
  local lower; lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  if command -v pkg-config >/dev/null && pkg-config --exists "$lower" 2>/dev/null; then return 0; fi
  find /usr/lib /usr/lib64 /usr/local/lib /usr/share -type f \
      \( -name "${1}Config.cmake" -o -name "$(printf '%s' "$lower")-config.cmake" \) 2>/dev/null | grep -q .
}
if [ "$SDL_CHOICE" = auto ]; then
  if sdl_found SDL3; then SDL_BACKEND=SDL3
  elif sdl_found SDL2; then SDL_BACKEND=SDL2
  else die "neither SDL3 nor SDL2 development files were found" \
           "Install one: sudo apt install libsdl3-dev   (or libsdl2-dev)"; fi
else
  SDL_BACKEND="$SDL_CHOICE"
  sdl_found "$SDL_BACKEND" || die "$SDL_BACKEND development files were not found" \
    "Install them: sudo apt install lib$(printf '%s' "$SDL_BACKEND" | tr '[:upper:]' '[:lower:]')-dev"
fi
info "SDL backend: $SDL_BACKEND"
gles2_only=0
for arg in "${EXTRA_CMAKE[@]}"; do
  case "$arg" in
    -DSNESRECOMP_SDL_GLES2_ONLY=ON|-DSNESRECOMP_SDL_GLES2_ONLY:BOOL=ON|-DSNESRECOMP_SDL_GLES2_ONLY=TRUE|-DSNESRECOMP_SDL_GLES2_ONLY=1)
      gles2_only=1
      ;;
  esac
done
if [ "$gles2_only" -eq 1 ]; then
  info "Strict GLES2-only mode: desktop OpenGL development files are not required."
elif command -v pkg-config >/dev/null && ! pkg-config --exists gl 2>/dev/null; then
  warn "Desktop OpenGL development files not found by pkg-config (sudo apt install libgl1-mesa-dev)"
fi
# -------------------------------------------------------------------- ROM --
# SHA-256 of the ROM payload. A 512-byte copier header (size 512 past a 1 KiB
# boundary) is skipped, exactly as the game (rom_image_verify.c) and the
# recompiler (snes65816.load_rom) skip it.
rom_sha() {
  local size; size="$(wc -c <"$1")"
  if [ $((size % 1024)) -eq 512 ]; then tail -c +513 "$1" | sha256sum | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}
if [ -n "$ROM_SRC" ]; then
  step "Staging ROM"
  [ -f "$ROM_SRC" ] || die "ROM not found: $ROM_SRC"
  sha="$(rom_sha "$ROM_SRC")"
  [ "$sha" = "$USA_ROM_SHA" ] || die "$ROM_SRC is not the supported Mega Man X (USA) ROM" \
      "sha256 $sha (copier header excluded)" "expected $USA_ROM_SHA (Mega Man X USA v1.1)"
  if [ -e mmx.sfc ] && [ "$(rom_sha mmx.sfc)" != "$USA_ROM_SHA" ]; then
    die "./mmx.sfc exists but is a different file; move it aside first"
  fi
  [ -e mmx.sfc ] && [ "$(readlink -f "$ROM_SRC")" = "$(readlink -f mmx.sfc)" ] ||
    cp -f "$ROM_SRC" mmx.sfc
  info "mmx.sfc verified"
  # A new ROM with no generated code yet means the user wants a full build.
  [ -f src/gen/dispatch_v2.c ] || REGEN=1
fi

# --------------------------------------------------------- generated code --
gen_ready() { [ -f src/gen/dispatch_v2.c ]; }
# What src/gen was generated from: the bank configs, the override script and
# the recompiler commit. Recorded after every regeneration this script runs.
GEN_STAMP=src/gen/.build-linux-dev.inputs
gen_inputs() {
  { cat recomp/bank*.cfg tools/apply_overrides.py
    git -C snesrecomp rev-parse HEAD; } 2>/dev/null | sha256sum | awk '{print $1}'
}
# Why src/gen is out of date, or nothing when it looks current.
gen_stale_reason() {
  if [ -f "$GEN_STAMP" ]; then
    [ "$(cat "$GEN_STAMP")" = "$(gen_inputs)" ] ||
      echo "bank configs, overrides or snesrecomp changed since the last regeneration"
    return 0
  fi
  local newer
  newer="$(find recomp tools/apply_overrides.py -maxdepth 1 \( -name 'bank*.cfg' -o -name apply_overrides.py \) \
      -newer src/gen/dispatch_v2.c 2>/dev/null | head -3 | tr '\n' ' ')"
  [ -z "$newer" ] || echo "newer than src/gen: $newer"
}
if [ "$SETUP_HOST" = 0 ]; then
  step "Checking generated code"
  if [ "$REGEN" = 0 ] && ! gen_ready; then
    if [ -f mmx.sfc ] && [ "$NO_REGEN" = 0 ]; then
      info "src/gen is missing; regenerating from ./mmx.sfc"
      REGEN=1
    else
      die "src/gen is missing and no ROM is staged" \
          "Stage your ROM:   bash $(basename "$0") --rom /path/to/mmx.sfc" \
          "or build ROM-free: bash $(basename "$0") --setup-host"
    fi
  fi
  if [ "$REGEN" = 0 ]; then
    reason="$(gen_stale_reason)"
    if [ -n "$reason" ]; then
      if [ -f mmx.sfc ] && [ "$NO_REGEN" = 0 ]; then
        info "src/gen is out of date ($reason); regenerating"
        REGEN=1
      else
        warn "src/gen looks out of date ($reason)"
        warn "an outdated src/gen fails to link (undefined Hle* symbols); run with --regen"
      fi
    fi
  fi
  if [ "$REGEN" = 1 ]; then
    [ -f mmx.sfc ] || die "--regen needs ./mmx.sfc" "Use --rom /path/to/rom.sfc"
    sha="$(rom_sha mmx.sfc)"
    [ "$sha" = "$USA_ROM_SHA" ] || die "./mmx.sfc is not the supported Mega Man X (USA) ROM" \
        "sha256 $sha (copier header excluded)" "expected $USA_ROM_SHA (Mega Man X USA v1.1)"
    if [ "${SNESRECOMP_ANALYSIS_BACKEND:-native}" = native ] && ! command -v cargo >/dev/null; then
      die "regeneration uses the Rust analyzer, but cargo is not installed" \
          "Install Rust from https://rustup.rs/ or set SNESRECOMP_ANALYSIS_BACKEND=python"
    fi
    step "Regenerating src/gen (this takes a while)"
    PYTHON="$PYTHON" bash tools/regen.sh usa --no-tests
    gen_ready || die "regeneration finished without src/gen/dispatch_v2.c"
    gen_inputs > "$GEN_STAMP"
  fi
  info "src/gen ready"
  if [ "$ALL" = 1 ] && [ ! -f variants/jp/gen/dispatch_v2.c ]; then
    info "Rockman X (JP) is not generated; it will be skipped (tools/regen.sh jp)"
  fi
fi

# ------------------------------------------------------------- build dir --
if [ "$CLEAN" = 1 ] && [ -d "$BUILD_DIR" ]; then
  step "Removing $BUILD_DIR"
  rm -rf -- "$BUILD_DIR"
fi
CACHE="$BUILD_DIR/CMakeCache.txt"
cache_get() { sed -n "s/^$1:[A-Z]*=//p" "$CACHE" 2>/dev/null | head -1; }
if [ -f "$CACHE" ] && [ "$FRESH" = 0 ]; then
  old_gen="$(cache_get CMAKE_GENERATOR)"
  old_src="$(cache_get CMAKE_HOME_DIRECTORY)"
  if [ -n "$old_gen" ] && [ "$old_gen" != "$CMAKE_GENERATOR" ]; then
    info "build dir used '$old_gen'; reconfiguring for '$CMAKE_GENERATOR'"; FRESH=1
  elif [ -n "$old_src" ] && [ "$(readlink -f "$old_src")" != "$(readlink -f "$REPO")" ]; then
    info "build dir belongs to $old_src; reconfiguring"; FRESH=1
  fi
fi
if [ "$FRESH" = 1 ] && [ -d "$BUILD_DIR" ]; then
  rm -rf -- "$CACHE" "$BUILD_DIR/CMakeFiles"
fi

# -------------------------------------------------------------- configure --
if [ -z "$VERSION" ]; then
  VERSION="$(git describe --tags --exact-match 2>/dev/null | sed 's/^v//' || true)"
  [ -n "$VERSION" ] || VERSION="dev"
fi
CONFIG_ARGS=(
  -G "$CMAKE_GENERATOR"
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
  -DSNESRECOMP_SDL_BACKEND="$SDL_BACKEND"
  -DSNESRECOMP_SETUP_HOST="$([ "$SETUP_HOST" = 1 ] && echo ON || echo OFF)"
  -DSNESRECOMP_ENABLE_TRACE="$([ "$TRACE" = 1 ] && echo ON || echo OFF)"
  -DSNESRECOMP_BUILD_VERSION="$VERSION"
)
[ -n "${CC:-}" ] && CONFIG_ARGS+=(-DCMAKE_C_COMPILER="$CC")
[ -n "${CXX:-}" ] && CONFIG_ARGS+=(-DCMAKE_CXX_COMPILER="$CXX")
if [ -n "$LIBJUICE_DIR" ]; then
  [ -f "$LIBJUICE_DIR/CMakeLists.txt" ] || die "--libjuice-dir has no CMakeLists.txt: $LIBJUICE_DIR"
  CONFIG_ARGS+=(-DFETCHCONTENT_SOURCE_DIR_LIBJUICE="$(readlink -f "$LIBJUICE_DIR")")
fi
[ "$OFFLINE" = 1 ] && CONFIG_ARGS+=(-DFETCHCONTENT_FULLY_DISCONNECTED=ON)
CONFIG_ARGS+=("${EXTRA_CMAKE[@]}")

step "Configuring $BUILD_DIR ($BUILD_TYPE, $SDL_BACKEND, version $VERSION)"
mkdir -p "$BUILD_DIR"
CONFIG_LOG="$BUILD_DIR/configure.log"
if ! "$CMAKE" -S "$REPO" -B "$BUILD_DIR" "${CONFIG_ARGS[@]}" >"$CONFIG_LOG" 2>&1; then
  grep -E -A12 'CMake Error|Could not find' "$CONFIG_LOG" | head -40 >&2 || tail -40 "$CONFIG_LOG" >&2
  hints=("Full log: $CONFIG_LOG")
  grep -q 'libjuice' "$CONFIG_LOG" && grep -qi 'download' "$CONFIG_LOG" &&
    hints+=("libjuice could not be downloaded. Clone it and pass --libjuice-dir:"
            "  git clone -b v1.7.2 https://github.com/paullouisageneau/libjuice ~/libjuice")
  grep -q "${SDL_BACKEND}Config.cmake" "$CONFIG_LOG" &&
    hints+=("CMake could not find $SDL_BACKEND; try --sdl SDL2 or install its -dev package")
  grep -q 'does not match the source' "$CONFIG_LOG" && hints+=("Rerun with --fresh")
  die "configure failed" "${hints[@]}"
fi
info "configured (log: ${CONFIG_LOG#"$REPO"/})"

# ------------------------------------------------------------------ build --
if [ "$ALL" = 1 ]; then
  BUILD_TARGETS=(all)
else
  [ ${#TARGETS[@]} -gt 0 ] || TARGETS=(MegaManXSNESRecomp)
  BUILD_TARGETS=("${TARGETS[@]}")
  [ "$TESTS" = 1 ] && BUILD_TARGETS+=("${CI_TESTS[@]}")
fi
step "Building ${BUILD_TARGETS[*]}"
BUILD_ARGS=(--build "$BUILD_DIR" --parallel "$JOBS")
for t in "${BUILD_TARGETS[@]}"; do BUILD_ARGS+=(--target "$t"); done
[ "$VERBOSE" = 1 ] && BUILD_ARGS+=(--verbose)
started=$SECONDS
BUILD_LOG="$BUILD_DIR/build.log"
if ! "$CMAKE" "${BUILD_ARGS[@]}" 2>&1 | tee "$BUILD_LOG"; then
  hints=("Full log: $BUILD_LOG")
  if grep -Eq "undefined reference to .Hle|src/gen/[^ ]*: .*error:|_widescreen_overrides|no bank\*_v2\.c under" "$BUILD_LOG"; then
    hints+=("The generated code in src/gen does not match this checkout."
            "Regenerate it:  bash $(basename "$0") --regen")
  fi
  grep -q "No space left on device" "$BUILD_LOG" && hints+=("The disk is full.")
  die "build failed" "${hints[@]}"
fi
info "built in $((SECONDS - started))s"

if [ "$TESTS" = 1 ]; then
  step "Running unit tests"
  ctest --test-dir "$BUILD_DIR" --output-on-failure -j "$JOBS"
fi

# ---------------------------------------------------------------- summary --
BIN="$BUILD_DIR/MegaManXSNESRecomp"
step "Done"
if [ -x "$BIN" ]; then
  printf '    %s%s%s (%s)\n' "$GRN" "${BIN#"$REPO"/}" "$RST" "$(du -h "$BIN" | cut -f1)"
  [ -x "$BUILD_DIR/RockmanXSNESRecomp" ] && info "${BUILD_DIR#"$REPO"/}/RockmanXSNESRecomp"
  [ "$SETUP_HOST" = 1 ] && info "ROM-free setup host: the launcher needs a ROM to play"
fi

if [ "$RUN" = 1 ]; then
  [ -x "$BIN" ] || die "nothing to run: $BIN was not built"
  step "Running ${BIN#"$REPO"/}"
  cd "$BUILD_DIR"
  exec "$BIN" "${RUN_ARGS[@]}"
fi
