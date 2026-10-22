# SPDX-License-Identifier: GPL-3.0-or-later
# CMake toolchain: aarch64 Linux (glibc 2.28) with `zig cc`.
# cmake -DCMAKE_TOOLCHAIN_FILE=tools/toolchain/aarch64-linux.cmake -DDENA_ZIG=<zig>
# Spec: docs/specs/toolchain-linux.md
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

if(NOT DENA_ZIG)
  set(DENA_ZIG $ENV{DENA_ZIG})
endif()
if(NOT DENA_ZIG)
  message(FATAL_ERROR "Set DENA_ZIG to the zig executable (tools/toolchain/zig.sh)")
endif()
# Try-compile projects re-read this file; pass the setting on.
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES DENA_ZIG)

set(DENA_ZIG_TARGET aarch64-linux-gnu.2.28)

# zig takes a subcommand, so CMake gets small wrappers.
set(_wrap ${CMAKE_BINARY_DIR}/zig-wrappers)
file(MAKE_DIRECTORY ${_wrap})
if(CMAKE_HOST_WIN32)
  file(TO_NATIVE_PATH "${DENA_ZIG}" _zig)
  # With sysroot libraries (DENA_LIBDIR), compile through zig-cc.sh: zig's
  # -l:<path> hand-off to lld fails on Windows, the script names the file.
  if(DENA_LIBDIR)
    list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES DENA_LIBDIR)
    find_program(DENA_BASH bash REQUIRED)
    set(_script "${CMAKE_CURRENT_LIST_DIR}/zig-cc.sh")
  endif()
  foreach(tool cc c++ ar ranlib)
    if(DENA_LIBDIR AND (tool STREQUAL "cc" OR tool STREQUAL "c++"))
      file(WRITE ${_wrap}/zig-${tool}.cmd
        "@set \"DENA_ZIG=${DENA_ZIG}\"\r\n@set \"DENA_LIBDIR=${DENA_LIBDIR}\"\r\n@\"${DENA_BASH}\" \"${_script}\" ${tool} %*\r\n")
      continue()
    endif()
    if(tool STREQUAL "cc" OR tool STREQUAL "c++")
      set(_args "${tool} -target ${DENA_ZIG_TARGET}")
    else()
      set(_args "${tool}")
    endif()
    file(WRITE ${_wrap}/zig-${tool}.cmd "@\"${_zig}\" ${_args} %*\r\n")
  endforeach()
  set(_ext .cmd)
else()
  foreach(tool cc c++ ar ranlib)
    if(tool STREQUAL "cc" OR tool STREQUAL "c++")
      set(_args "${tool} -target ${DENA_ZIG_TARGET}")
    else()
      set(_args "${tool}")
    endif()
    file(WRITE ${_wrap}/zig-${tool} "#!/bin/sh\nexec \"${DENA_ZIG}\" ${_args} \"$@\"\n")
    file(CHMOD ${_wrap}/zig-${tool} PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE)
  endforeach()
  set(_ext "")
endif()

set(CMAKE_C_COMPILER ${_wrap}/zig-cc${_ext})
set(CMAKE_CXX_COMPILER ${_wrap}/zig-c++${_ext})
set(CMAKE_AR ${_wrap}/zig-ar${_ext} CACHE FILEPATH "" FORCE)
set(CMAKE_RANLIB ${_wrap}/zig-ranlib${_ext} CACHE FILEPATH "" FORCE)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
