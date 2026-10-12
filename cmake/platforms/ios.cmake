# iOS specific settings

if(NOT IOS)
    return()
endif()

# The GL1 renderer is fixed-function and aborts on OpenGL ES (see sdl_glimp.c)
set(BUILD_SERVER OFF CACHE INTERNAL "")
set(BUILD_RENDERER_GL1 OFF CACHE INTERNAL "")
set(USE_RENDERER_DLOPEN OFF CACHE INTERNAL "")
set(USE_OPENAL_DLOPEN OFF CACHE INTERNAL "")

# Cocoa based sys_osx.m is macOS only
list(APPEND SYSTEM_PLATFORM_SOURCES ${SOURCE_DIR}/sys/sys_ios.c)

# On-screen touch controls (UIKit overlay)
enable_language(OBJC)
list(APPEND SYSTEM_PLATFORM_SOURCES ${SOURCE_DIR}/sys/sys_ios_touch.m)
set_source_files_properties(${SOURCE_DIR}/sys/sys_ios_touch.m PROPERTIES COMPILE_OPTIONS -fobjc-arc)
list(APPEND CLIENT_LIBRARIES "-framework UIKit")
