# Native part of the Android shell. Spec: docs/specs/latency-spike.md,
# docs/specs/shared-runner.md
cmake_minimum_required(VERSION 3.22)
project(dena_android C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
get_filename_component(DENA_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../.." ABSOLUTE)

find_package(oboe REQUIRED CONFIG)

# RetroAchievements (docs/specs/achievements.md).
file(GLOB_RECURSE DENA_RCHEEVOS_SOURCES ${DENA_ROOT}/host/third_party/rcheevos/src/*.c)
add_library(rcheevos STATIC ${DENA_RCHEEVOS_SOURCES})
target_include_directories(rcheevos
  PUBLIC ${DENA_ROOT}/host/third_party/rcheevos/include
  PRIVATE ${DENA_ROOT}/host/third_party/rcheevos/src ${DENA_ROOT}/host/third_party/libretro)
target_compile_definitions(rcheevos PUBLIC RC_CLIENT_SUPPORTS_HASH RC_HASH_NO_ENCRYPTED)
target_compile_options(rcheevos PRIVATE -w)

add_library(dena_android SHARED
  runner.cpp
  gl_presenter.cpp
  ${DENA_ROOT}/host/runner/runner.cpp
  ${DENA_ROOT}/host/runner/netplay_session.cpp
  ${DENA_ROOT}/host/runner/rewind_scrub.cpp
  ${DENA_ROOT}/host/src/host.c
  ${DENA_ROOT}/host/src/frame.c
  ${DENA_ROOT}/host/src/replay.c
  ${DENA_ROOT}/host/src/audio.c
  ${DENA_ROOT}/host/src/session.c
  ${DENA_ROOT}/host/src/rewind.c
  ${DENA_ROOT}/host/src/link.c
  ${DENA_ROOT}/host/src/net_room.c
  ${DENA_ROOT}/host/achievements/achievements.cpp
  ${DENA_ROOT}/host/render/src/shader_preset.cpp
  ${DENA_ROOT}/host/render/src/shader_chain.cpp)
target_include_directories(dena_android PRIVATE
  ${DENA_ROOT}/host/include
  ${DENA_ROOT}/host/runner
  ${DENA_ROOT}/host/achievements
  ${DENA_ROOT}/host/third_party/rcheevos/src
  ${DENA_ROOT}/host/render/include
  ${DENA_ROOT}/host/third_party/libretro)
target_compile_options(dena_android PRIVATE -Wall -Wextra)
target_link_libraries(dena_android PRIVATE oboe::oboe rcheevos android log EGL GLESv3)
