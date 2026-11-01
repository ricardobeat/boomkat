# boomkat CMake package. Installed by `make install` into
# <prefix>/lib/cmake/boomkat; from a source tree, point boomkat_DIR at cmake/
# after `make lib`.
#   find_package(boomkat REQUIRED)
#   target_link_libraries(app PRIVATE boomkat::cpp)   # or boomkat::c
# Set BOOMKAT_SHARED=ON before find_package to link the shared library.
get_filename_component(_bk_dir "${CMAKE_CURRENT_LIST_DIR}" ABSOLUTE)
if(EXISTS "${_bk_dir}/../include/boomkat.h")
  # Source tree: cmake/ next to include/ and out/.
  get_filename_component(_bk_root "${_bk_dir}/.." ABSOLUTE)
  set(_bk_inc "${_bk_root}/include")
  set(_bk_static "${_bk_root}/out/boomkat.a")
  set(_bk_shared "${_bk_root}/out/libboomkat${CMAKE_SHARED_LIBRARY_SUFFIX}")
else()
  # Installed: <prefix>/lib/cmake/boomkat.
  get_filename_component(_bk_root "${_bk_dir}/../../.." ABSOLUTE)
  set(_bk_inc "${_bk_root}/include")
  set(_bk_static "${_bk_root}/lib/libboomkat.a")
  set(_bk_shared "${_bk_root}/lib/libboomkat${CMAKE_SHARED_LIBRARY_SUFFIX}")
endif()

if(NOT TARGET boomkat::c)
  if(BOOMKAT_SHARED)
    add_library(boomkat::c SHARED IMPORTED)
    set_target_properties(boomkat::c PROPERTIES IMPORTED_LOCATION "${_bk_shared}")
  else()
    add_library(boomkat::c STATIC IMPORTED)
    set_target_properties(boomkat::c PROPERTIES IMPORTED_LOCATION "${_bk_static}")
    if(NOT APPLE AND NOT WIN32)
      set_property(TARGET boomkat::c PROPERTY INTERFACE_LINK_LIBRARIES m dl)
    endif()
  endif()
  set_target_properties(boomkat::c PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "${_bk_inc}")

  add_library(boomkat::cpp INTERFACE IMPORTED)
  set_property(TARGET boomkat::cpp PROPERTY INTERFACE_LINK_LIBRARIES boomkat::c)
  set_property(TARGET boomkat::cpp PROPERTY INTERFACE_COMPILE_FEATURES cxx_std_17)
endif()
set(boomkat_FOUND TRUE)
unset(_bk_dir)
unset(_bk_root)
unset(_bk_inc)
unset(_bk_static)
unset(_bk_shared)
