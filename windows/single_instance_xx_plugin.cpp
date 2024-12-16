#include "include/single_instance_xx/single_instance_xx_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <map>
#include <memory>
#include <sstream>

namespace {

// Converts the given UTF-8 string to UTF-16.
// https://github.com/flutter/plugins/blob/main/packages/url_launcher/url_launcher_windows/windows/url_launcher_plugin.cpp
std::wstring Utf16FromUtf8(const std::string& utf8_string) {
  if (utf8_string.empty()) {
    return std::wstring();
  }
  int target_length =
      ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8_string.data(),
                            static_cast<int>(utf8_string.length()), nullptr, 0);
  if (target_length == 0) {
    return std::wstring();
  }
  std::wstring utf16_string;
  utf16_string.resize(target_length);
  int converted_length =
      ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8_string.data(),
                            static_cast<int>(utf8_string.length()),
                            utf16_string.data(), target_length);
  if (converted_length == 0) {
    return std::wstring();
  }
  return utf16_string;
}

class SingleInstancexxPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  SingleInstancexxPlugin(flutter::PluginRegistrarWindows *registrar);

  virtual ~SingleInstancexxPlugin();

 private:
  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  bool isSingleInstance(std::wstring pipe);

  private:
    HANDLE mutex = NULL;
    flutter::PluginRegistrarWindows *registrar_;
};

// static
void SingleInstancexxPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "single_instance_xx",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<SingleInstancexxPlugin>(registrar);

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

SingleInstancexxPlugin::SingleInstancexxPlugin(flutter::PluginRegistrarWindows *registrar) 
  : registrar_(registrar) {}

SingleInstancexxPlugin::~SingleInstancexxPlugin() {
  if (mutex != NULL) {
      ::ReleaseMutex(mutex);
  }
}

void SingleInstancexxPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name().compare("isSingleInstance") == 0) {

    const auto* arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
    std::string pipe;

    if (arguments) {
        auto pipe_it = arguments->find(flutter::EncodableValue("pipe"));
        if (pipe_it != arguments->end()) {
            pipe = std::get<std::string>(pipe_it->second);

            result->Success(flutter::EncodableValue(isSingleInstance(Utf16FromUtf8(pipe))));
            return;
        }
    }
  }
  else if (method_call.method_name().compare("bringToFront") == 0)
  {
    // https://stackoverflow.com/questions/916259/win32-bring-a-window-to-top/34414846#34414846

    HWND m_hWnd = registrar_->GetView()->GetNativeWindow();

    // Find parent window
    HWND parent = ::GetAncestor(m_hWnd, GA_ROOT);
    if (parent != NULL) {
      m_hWnd = parent;
    }

    HWND hCurWnd = ::GetForegroundWindow();
    DWORD dwMyID = ::GetCurrentThreadId();
    DWORD dwCurID = ::GetWindowThreadProcessId(hCurWnd, NULL);
    ::AttachThreadInput(dwCurID, dwMyID, TRUE);
    ::SetWindowPos(m_hWnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE);
    ::SetWindowPos(m_hWnd, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_SHOWWINDOW | SWP_NOSIZE | SWP_NOMOVE);
    ::SetForegroundWindow(m_hWnd);
    ::SetFocus(m_hWnd);
    ::SetActiveWindow(m_hWnd);
    ::AttachThreadInput(dwCurID, dwMyID, FALSE);
    if (::IsIconic(m_hWnd)) {
      ::ShowWindow(m_hWnd, SW_RESTORE);
    }
    result->Success();
    return;
  }

  result->NotImplemented();
}

bool SingleInstancexxPlugin::isSingleInstance(std::wstring name) {
  // Only call once
  if (mutex != NULL) {
    return true;
  }

  // Check for existing window
  std::wstring mutex_str = name.append(L".win.mutex");
  mutex = ::CreateMutex(NULL, TRUE, mutex_str.c_str());
  if (mutex == NULL || GetLastError() == ERROR_ALREADY_EXISTS) {
      return false;
  }

  return true;
}

}  // namespace

void SingleInstancexxPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  SingleInstancexxPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
