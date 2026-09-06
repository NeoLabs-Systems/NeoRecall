cmake_minimum_required(VERSION 3.22)
project(lame16k C)

set(LAME_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/lame-3.100")
if(NOT EXISTS "${LAME_ROOT}/libmp3lame/lame.c")
  message(FATAL_ERROR "lame-3.100 sources are missing; run build_lame.sh")
endif()

add_library(mp3lame STATIC
  ${LAME_ROOT}/libmp3lame/bitstream.c
  ${LAME_ROOT}/libmp3lame/encoder.c
  ${LAME_ROOT}/libmp3lame/fft.c
  ${LAME_ROOT}/libmp3lame/gain_analysis.c
  ${LAME_ROOT}/libmp3lame/id3tag.c
  ${LAME_ROOT}/libmp3lame/lame.c
  ${LAME_ROOT}/libmp3lame/newmdct.c
  ${LAME_ROOT}/libmp3lame/presets.c
  ${LAME_ROOT}/libmp3lame/psymodel.c
  ${LAME_ROOT}/libmp3lame/quantize.c
  ${LAME_ROOT}/libmp3lame/quantize_pvt.c
  ${LAME_ROOT}/libmp3lame/reservoir.c
  ${LAME_ROOT}/libmp3lame/set_get.c
  ${LAME_ROOT}/libmp3lame/tables.c
  ${LAME_ROOT}/libmp3lame/takehiro.c
  ${LAME_ROOT}/libmp3lame/util.c
  ${LAME_ROOT}/libmp3lame/vbrquantize.c
  ${LAME_ROOT}/libmp3lame/VbrTag.c
  ${LAME_ROOT}/libmp3lame/version.c
)
target_include_directories(mp3lame PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${LAME_ROOT}/include
  ${LAME_ROOT}/libmp3lame
)
target_compile_definitions(mp3lame PRIVATE STDC_HEADERS=1 HAVE_STRCHR=1)
target_compile_options(mp3lame PRIVATE -w -include "${CMAKE_CURRENT_SOURCE_DIR}/config.h")

add_library(lame SHARED jni_lame.c)
target_include_directories(lame PRIVATE ${LAME_ROOT}/include)
target_link_libraries(lame PRIVATE mp3lame log m)
target_link_options(lame PRIVATE
    -Wl,-z,max-page-size=16384
    -Wl,-z,common-page-size=16384
)
set_target_properties(lame PROPERTIES OUTPUT_NAME lame)
