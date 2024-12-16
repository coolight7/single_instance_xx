import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
// TODO remove path_provider as it introduces a flutter dependency
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';

void debugPrint(dynamic str) {
  if (SingleInstancexx._kDebugMode) {
    // ignore: avoid_print
    print(str);
  }
}

class SingleInstancexx {
  static bool _kDebugMode = false;

  SingleInstancexx._();

  /// Checks that the current window is unique, and exits the app not.
  ///
  /// __Arguments__\
  /// `arguments`: List of strings that will be passed to the callback function of the open instance if this window is not unique\
  /// `pipeName`: A string unique to your app\
  /// `onSecondWindow`: Callback function that is called when a second window is attempted to be opened.
  static Future<bool> signSingleInstance(
    List<String> arguments,
    String pipeName, {
    Function(List<String>)? onRecvSecondWindowMsg,
    bool kDebugMode = false,
  }) async {
    _kDebugMode = kDebugMode;
    if (Platform.isWindows) {
      return _WindowsHandle.handle(
        arguments,
        pipeName,
        onRecvSecondWindowMsg: onRecvSecondWindowMsg,
      );
    } else if (Platform.isMacOS || Platform.isLinux) {
      return await _UnixHandle.handle(arguments, (args) {
        if (onRecvSecondWindowMsg != null) {
          onRecvSecondWindowMsg(args);
        }
      });
    }
    return false;
  }
}

class _WindowsHandle {
  static const MethodChannel _channel = MethodChannel('single_instance_xx');
  static const _kErrorPipeConnected = 0x80070217;

  static int _openPipe(String filename) {
    final cPipe = filename.toNativeUtf16();
    try {
      return CreateFile(
        cPipe,
        GENERIC_ACCESS_RIGHTS.GENERIC_WRITE,
        0,
        nullptr,
        FILE_CREATION_DISPOSITION.OPEN_EXISTING,
        0,
        0,
      );
    } finally {
      free(cPipe);
    }
  }

  static int _createPipe(String filename) {
    final cPipe = filename.toNativeUtf16();
    try {
      return CreateNamedPipe(
        cPipe,
        FILE_FLAGS_AND_ATTRIBUTES.PIPE_ACCESS_INBOUND |
            FILE_FLAGS_AND_ATTRIBUTES.FILE_FLAG_FIRST_PIPE_INSTANCE |
            FILE_FLAGS_AND_ATTRIBUTES.FILE_FLAG_OVERLAPPED,
        NAMED_PIPE_MODE.PIPE_TYPE_MESSAGE |
            NAMED_PIPE_MODE.PIPE_READMODE_MESSAGE |
            NAMED_PIPE_MODE.PIPE_WAIT,
        PIPE_UNLIMITED_INSTANCES,
        4096,
        4096,
        0,
        nullptr,
      );
    } finally {
      malloc.free(cPipe);
    }
  }

  static void _readPipe(SendPort writer, int pipeHandle) {
    final overlap = calloc<OVERLAPPED>();
    try {
      while (true) {
        while (true) {
          ConnectNamedPipe(pipeHandle, overlap);
          final err = GetLastError();
          if (err == _kErrorPipeConnected) {
            sleep(const Duration(milliseconds: 200));
            continue;
          } else if (err == WIN32_ERROR.ERROR_INVALID_HANDLE) {
            return;
          }
          break;
        }

        var dataSize = 16384;
        var data = calloc<Uint8>(dataSize);
        final numRead = calloc<Uint32>();
        try {
          while (GetOverlappedResult(pipeHandle, overlap, numRead, 0) == 0) {
            sleep(const Duration(milliseconds: 200));
          }

          ReadFile(pipeHandle, data, dataSize, numRead, overlap);
          final jsonData = data.cast<Utf8>().toDartString();
          writer.send(jsonDecode(jsonData));
        } catch (error) {
          stderr.writeln("[MultiInstanceHandler]: ERROR: $error");
        } finally {
          free(data);
          free(numRead);
          DisconnectNamedPipe(pipeHandle);
        }
      }
    } finally {
      free(overlap);
    }
  }

  static void _writePipeData(String filename, List<String>? arguments) {
    final pipe = _openPipe(filename);
    final bytesString = jsonEncode(arguments ?? []);
    final bytes = bytesString.toNativeUtf8();
    final numWritten = malloc<Uint32>();
    try {
      WriteFile(pipe, bytes.cast<Uint8>(), bytes.length, numWritten, nullptr);
    } finally {
      free(numWritten);
      free(bytes);
      CloseHandle(pipe);
    }
  }

  static void _startReadPipeIsolate(Map args) {
    final pipe = _createPipe(args["pipe"] as String);
    if (pipe == INVALID_HANDLE_VALUE) {
      debugPrint("Pipe create failed");
      return;
    }
    _readPipe(args["port"] as SendPort, pipe);
  }

  static Future<bool> handle(
    List<String> arguments,
    String pipeName, {
    Function(List<String>)? onRecvSecondWindowMsg,
  }) async {
    final fullPipeName = "\\\\.\\pipe\\$pipeName";
    final bool isSingleInstance = await _channel
        .invokeMethod('isSingleInstance', <String, Object>{"pipe": pipeName});
    if (!isSingleInstance) {
      // 已经存在窗口，当前非第一个
      _writePipeData(fullPipeName, arguments);
      return false;
    }

    // No callback so don't bother starting pipe
    if (onRecvSecondWindowMsg == null) {
      return true;
    }

    final reader = ReceivePort()
      ..listen((dynamic msg) {
        if (msg is List) {
          onRecvSecondWindowMsg(msg.map((o) => o.toString()).toList());
        }
      });
    await Isolate.spawn(
        _startReadPipeIsolate, {"port": reader.sendPort, "pipe": fullPipeName});
    return true;
  }
}

class _UnixHandle {
  static Future<bool> handle(
    List<String> arguments,
    void Function(List<String> args) onRecvSecondWindowMsg,
  ) async {
    // TODO make a named arg
    // Kept short because of mac os x sandboxing makes the name too long for unix sockets.
    var socketFilename = 'socket';
    // TODO make configurable so it can be per X, per User, or for the whole machine based on optional named args
    var configPath = await _applicationConfigDirectory();
    await Directory(configPath).create(recursive: true);
    var socketFilepath = p.join(configPath, socketFilename);
    final InternetAddress host =
        InternetAddress(socketFilepath, type: InternetAddressType.unix);
    var socketFile = File(socketFilepath);
    if (await socketFile.exists()) {
      debugPrint("Found existing instance!");
      var messageSent = await _sendArgsToUixSocket(arguments, host);
      if (messageSent) {
        debugPrint("Message sent");
        debugPrint("Quiting");
        exit(0);
      } else {
        debugPrint("Deleting dead socket");
        await socketFile.delete();
      }
    }
    // TODO manage socket subscription, technically not required because OS clean up does the work "for" us but good practices.
    // StreamSubscription<Socket>? socket;
    try {
      /*socket = */ await _createUnixSocket(
        host,
        onRecvSecondWindowMsg,
      );
    } catch (e) {
      debugPrint("Socket create error");
      debugPrint(e);
      return false;
    }
    return true;
  }

// Simple function to get the appropriate file location to store using path_provider
// this should be replaced, especially if we are going to allow the user to specify
// if it's a single instance per {user, user&x, x, system, etc.}
  static Future<String> _applicationConfigDirectory() async {
    final String dbPath;
    if (Platform.isAndroid) {
      dbPath = (await getApplicationDocumentsDirectory()).path;
    } else if (Platform.isLinux || Platform.isWindows) {
      dbPath = (await getApplicationSupportDirectory()).path;
    } else if (Platform.isMacOS || Platform.isIOS) {
      dbPath = (await getApplicationDocumentsDirectory()).path;
    } else {
      dbPath = '';
    }
    return dbPath;
  }

// Call this at the top of your function, returns a bool. Which is "true" if this is the first instance,
// if this is the second instance (and it has transmitted the arguments across the socket) it returns
// false.
// cmdProcessor is what the first instance does once it receives the command line arguments from the previous
// kDebugMode makes the application noisy.

// JSON serializes the args, and sends across "the wire"
  static Future<bool> _sendArgsToUixSocket(
    List<String> args,
    InternetAddress host,
  ) async {
    try {
      var s = await Socket.connect(host, 0);
      s.writeln(jsonEncode(args));
      await s.close();
      return true;
    } catch (e) {
      debugPrint("Socket connect error");
      debugPrint(e);
      return false;
    }
  }

// Creates the unix socket, or cleans up if it exists but isn't valid and then
// recursively calls itself -- if the socket is valid, sends the args as json.
// Return stream subscription.
  static Future<StreamSubscription<Socket>> _createUnixSocket(
    InternetAddress host,
    void Function(List<String> args) onRecvSecondWindowMsg,
  ) async {
    debugPrint("creating socket");
    ServerSocket serverSocket = await ServerSocket.bind(host, 0);
    debugPrint("creating listening");
    var stream = serverSocket.listen((event) async {
      debugPrint("Event");
      debugPrint(event);
      const utf8decoder = Utf8Decoder();
      var args = StringBuffer();
      await event.forEach((Uint8List element) {
        args.write(utf8decoder.convert(element));
      });
      debugPrint("Second instance launched with: ${args.toString()}");
      try {
        List<dynamic> decodedArgs = jsonDecode(args.toString());
        final argStrings = <String>[];
        for (final item in decodedArgs) {
          argStrings.add(item);
        }
        onRecvSecondWindowMsg(argStrings);
      } catch (e) {
        debugPrint(e);
      }
    });
    return stream;
  }
}
