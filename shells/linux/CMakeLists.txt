# Linux handheld layer: platform modules (and later the power daemon and the
# embedder). The pure parts build and test on any host.
# Spec: docs/specs/platform-modules.md
cmake_minimum_required(VERSION 3.20)
project(dena_linux C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
  add_compile_options(-Wall -Wextra $<$<COMPILE_LANGUAGE:C>:-Werror=implicit-function-declaration>)
endif()

set(_gen ${CMAKE_CURRENT_BINARY_DIR}/gen/profiles_gen.h)
file(GLOB _confs ${CMAKE_CURRENT_SOURCE_DIR}/profiles/*.conf)
add_custom_command(
  OUTPUT ${_gen}
  COMMAND ${CMAKE_COMMAND} -DPROFILES_DIR=${CMAKE_CURRENT_SOURCE_DIR}/profiles
    -DOUT=${_gen} -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake_embed.cmake
  DEPENDS ${_confs} ${CMAKE_CURRENT_SOURCE_DIR}/cmake_embed.cmake)

add_library(dena_platform STATIC src/profile.c src/builtin_profiles.c src/power.c src/embedder_core.c src/std_codec.c src/input.c ${_gen})
target_include_directories(dena_platform
  PUBLIC include
  PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/gen)

# Game sessions in the launcher (handheld-session.md): the portable parts.
add_library(dena_session_core STATIC src/launcher/game_bridge.cpp src/launcher/frame_mailbox.cpp)
target_include_directories(dena_session_core PUBLIC src/launcher)
target_link_libraries(dena_session_core PUBLIC dena_platform)

# Device-side tools (need linux/input.h).
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  add_executable(dena-keytest src/keytest.c)
  target_link_libraries(dena-keytest PRIVATE dena_platform)
  add_executable(dena-powerd src/powerd.c)
  target_link_libraries(dena-powerd PRIVATE dena_platform)

  # The launcher needs libdrm, gbm and EGL: from DENA_SYSROOT when cross
  # building (tools/toolchain/sysroot.py), else the system's. Spec: embedder.md
  find_path(DENA_DRM_INCLUDE xf86drm.h PATHS ${DENA_SYSROOT}/usr/include NO_CMAKE_FIND_ROOT_PATH)
  find_library(DENA_DRM drm PATHS ${DENA_SYSROOT}/usr/lib/aarch64-linux-gnu NO_CMAKE_FIND_ROOT_PATH)
  find_library(DENA_GBM gbm PATHS ${DENA_SYSROOT}/usr/lib/aarch64-linux-gnu NO_CMAKE_FIND_ROOT_PATH)
  find_library(DENA_EGL EGL PATHS ${DENA_SYSROOT}/usr/lib/aarch64-linux-gnu NO_CMAKE_FIND_ROOT_PATH)
  find_library(DENA_GLES GLESv2 PATHS ${DENA_SYSROOT}/usr/lib/aarch64-linux-gnu NO_CMAKE_FIND_ROOT_PATH)
  find_library(DENA_ASOUND asound PATHS ${DENA_SYSROOT}/usr/lib/aarch64-linux-gnu NO_CMAKE_FIND_ROOT_PATH)
  if(DENA_DRM_INCLUDE AND DENA_DRM AND DENA_GBM AND DENA_EGL AND DENA_GLES AND DENA_ASOUND)
    # The emulator host and the shared runner are built in, as on Android.
    set(_host ${CMAKE_CURRENT_SOURCE_DIR}/../../host)
    # RetroAchievements (achievements.md), as on Android.
    file(GLOB_RECURSE _rcheevos_sources ${_host}/third_party/rcheevos/src/*.c)
    add_library(rcheevos STATIC ${_rcheevos_sources})
    target_include_directories(rcheevos
      PUBLIC ${_host}/third_party/rcheevos/include
      PRIVATE ${_host}/third_party/rcheevos/src ${_host}/third_party/libretro)
    target_compile_definitions(rcheevos PUBLIC RC_CLIENT_SUPPORTS_HASH RC_HASH_NO_ENCRYPTED)
    target_compile_options(rcheevos PRIVATE -w)
    set_target_properties(rcheevos PROPERTIES POSITION_INDEPENDENT_CODE ON)
    add_executable(dena-launcher src/launcher/launcher.c src/launcher/audio.c src/launcher/session.cpp
      src/launcher/linux_platform.cpp src/launcher/gl_target.cpp ${_host}/runner/runner.cpp ${_host}/runner/netplay_session.cpp
      ${_host}/runner/rewind_scrub.cpp
      ${_host}/src/host.c ${_host}/src/frame.c ${_host}/src/replay.c ${_host}/src/audio.c
      ${_host}/src/session.c ${_host}/src/rewind.c ${_host}/src/link.c ${_host}/src/net_room.c
      ${_host}/achievements/achievements.cpp
      ${_host}/render/src/shader_preset.cpp ${_host}/render/src/shader_chain.cpp)
    target_include_directories(dena-launcher PRIVATE
      ${DENA_DRM_INCLUDE} ${DENA_DRM_INCLUDE}/libdrm third_party/flutter
      ${_host}/include ${_host}/runner ${_host}/third_party/libretro ${_host}/render/include
      ${_host}/achievements ${_host}/third_party/rcheevos/src)
    target_compile_definitions(dena-launcher PRIVATE EGL_NO_X11 MESA_EGL_NO_X11_HEADERS)
    # Dart looks up dena_ram_*, dena_ra_*, dena_link_* and dena_set_turbo in
    # the process (pico8-launcher-cart.md, achievements.md, turbo.md).
    set_target_properties(dena-launcher PROPERTIES ENABLE_EXPORTS ON)
    target_link_libraries(dena-launcher PRIVATE dena_session_core dena_platform rcheevos
      ${DENA_DRM} ${DENA_GBM} ${DENA_EGL} ${DENA_GLES} ${DENA_ASOUND} pthread dl m)
    if(DENA_SYSROOT)
      # Debian's libraries need a newer glibc than we link against; the
      # device brings its own at run time.
      target_link_options(dena-launcher PRIVATE -Wl,--allow-shlib-undefined)
    endif()
  else()
    message(STATUS "dena-launcher skipped: no libdrm/gbm/EGL/GLES/ALSA (set DENA_SYSROOT)")
  endif()
endif()

include(CTest)
if(BUILD_TESTING)
  add_executable(platform_tests tests/platform_tests.c)
  target_link_libraries(platform_tests PRIVATE dena_platform)
  add_test(NAME platform COMMAND platform_tests)
  add_executable(power_tests tests/power_tests.c)
  target_link_libraries(power_tests PRIVATE dena_platform)
  add_test(NAME power COMMAND power_tests)
  add_executable(input_tests tests/input_tests.c)
  target_link_libraries(input_tests PRIVATE dena_platform)
  add_test(NAME input COMMAND input_tests)
  add_executable(embedder_tests tests/embedder_tests.c)
  target_link_libraries(embedder_tests PRIVATE dena_platform)
  if(NOT WIN32)
    target_link_libraries(embedder_tests PRIVATE m)
  endif()
  add_test(NAME embedder COMMAND embedder_tests)
  add_executable(codec_tests tests/codec_tests.c)
  target_link_libraries(codec_tests PRIVATE dena_platform)
  add_test(NAME codec COMMAND codec_tests)
  add_executable(bridge_tests tests/bridge_tests.cpp)
  target_link_libraries(bridge_tests PRIVATE dena_session_core)
  file(MAKE_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/bridge_card)
  add_test(NAME bridge COMMAND bridge_tests ${CMAKE_CURRENT_BINARY_DIR}/bridge_card)
  add_executable(mailbox_tests tests/mailbox_tests.cpp)
  target_link_libraries(mailbox_tests PRIVATE dena_session_core)
  if(MINGW)  # whichever libstdc++/winpthread DLL is first on PATH may not match
    target_link_options(bridge_tests PRIVATE -static)
    target_link_options(mailbox_tests PRIVATE -static)
  endif()
  if(NOT WIN32)
    find_package(Threads REQUIRED)
    target_link_libraries(mailbox_tests PRIVATE Threads::Threads)
  endif()
  add_test(NAME mailbox COMMAND mailbox_tests)
endif()
