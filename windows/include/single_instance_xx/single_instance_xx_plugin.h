#ifndef FLUTTER_PLUGIN_SINGLE_INSTANCE_XX_PLUGIN_H_
#define FLUTTER_PLUGIN_SINGLE_INSTANCE_XX_PLUGIN_H_

#include <flutter_plugin_registrar.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif

#if defined(__cplusplus)
extern "C" {
#endifX

FLUTTER_PLUGIN_EXPORT void SingleInstanceXxPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // FLUTTER_PLUGIN_SINGLE_INSTANCE_XX_PLUGIN_H_
