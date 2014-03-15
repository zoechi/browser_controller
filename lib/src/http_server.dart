// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library http_server;

import 'dart:async';
import 'dart:io';
import 'package:args/args.dart';
import 'package:path/path.dart' as path;
import 'utils.dart';


/// Interface of the HTTP server:
///
/// /echo: This will stream the data received in the request stream back
///        to the client.
/// /code_root/X: This will serve the corresponding file from the top level of
///               the project (the dart checkout or this package)
///               directory (i.e. '$DartDirectory/X').
/// /build_root/X: This will serve the corresponding file from the build
///                directory (i.e. '$BuildDirectory/X').
/// /FOO/packages/BAR: This will serve the corresponding file from the packages
///                    directory (i.e. '$BuildDirectory/packages/BAR')
///
/// In case a path does not refer to a file but rather to a directory, a
/// directory listing will be displayed.

const PREFIX_BUILDDIR = 'build_root';
const PREFIX_DARTDIR = 'code_root';

// TODO(kustermann,ricow): We could change this to the following scheme:
// http://host:port/root_packages/X -> $BuildDir/packages/X
// Issue: 8368

main(List<String> arguments) {
  /** Convenience method for local testing. */
  var parser = new ArgParser();
  parser.addOption('port', abbr: 'p',
      help: 'The main server port we wish to respond to requests.',
      defaultsTo: '0');
  parser.addOption('crossOriginPort', abbr: 'c',
      help: 'A different port that accepts request from the main server port.',
      defaultsTo: '0');
  parser.addFlag('help', abbr: 'h', negatable: false,
      help: 'Print this usage information.');
  parser.addOption('build-directory', help: 'The build directory to use.');
  parser.addOption('network', help: 'The network interface to use.',
      defaultsTo: '0.0.0.0');
  parser.addFlag('csp', help: 'Use Content Security Policy restrictions.',
      defaultsTo: false);
  parser.addOption('runtime', help: 'The runtime we are using (for csp flags).',
      defaultsTo: 'none');

  var args = parser.parse(arguments);
  if (args['help']) {
    print(parser.getUsage());
  }
}

/**
 * Runs a set of servers that are initialized specifically for the needs of our
 * test framework, such as dealing with package-root.
 */
class TestingServers {
  static final _CACHE_EXPIRATION_IN_SECONDS = 30;

  List _serverList = [];
  String _buildDirectory = null;
  final bool useContentSecurityPolicy;
  final String runtime;
  /** The top level directory that this server is serving from. */
  String _codeRoot;

  TestingServers(String buildDirectory,
                 String codeRoot,
                 this.useContentSecurityPolicy,
                 [String this.runtime = 'none']) {
    _buildDirectory = path.absolute(buildDirectory);
    _codeRoot = path.absolute(codeRoot);
  }

  int get port => _serverList[0].port;
  int get crossOriginPort => _serverList[1].port;

  /**
   * [startServers] will start two Http servers.
   * The first server listens on [port] and sets
   *   "Access-Control-Allow-Origin: *"
   * The second server listens on [crossOriginPort] and sets
   *   "Access-Control-Allow-Origin: client:port1
   *   "Access-Control-Allow-Credentials: true"
   */
  Future startServers(String host, {int port: 0, int crossOriginPort: 0}) {
    return _startHttpServer(host, port: port).then((server) {
      return _startHttpServer(host,
                              port: crossOriginPort,
                              allowedPort:_serverList[0].port);
    });
  }

  void stopServers() {
    for (var server in _serverList) {
      server.close();
    }
  }

  Future _startHttpServer(String host, {int port: 0, int allowedPort: -1}) {
    return HttpServer.bind(host, port).then((HttpServer httpServer) {
      httpServer.listen((HttpRequest request) {
        if (request.uri.path == "/echo") {
          _handleEchoRequest(request, request.response);
        } else {
          _handleFileRequest(
              request, request.response, allowedPort);
        }
      },
      onError: (e) {
        DebugLogger.error('HttpServer: an error occured', e);
      });
      _serverList.add(httpServer);
    });
  }

  void _handleFileRequest(HttpRequest request,
                          HttpResponse response,
                          int allowedPort) {
    // TODO: efortuna maybe don't want to do this...max expiration
    // Enable browsers to cache file/directory responses.
    response.headers.set("Cache-Control",
                         "max-age=$_CACHE_EXPIRATION_IN_SECONDS");
    var path = _getFilePathFromRequestPath(request.uri.path);
    if (path != null) {
      var file = new File(path);
      file.exists().then((exists) {
        if (exists) {
          _sendFileContent(request, response, allowedPort, path, file);
        } else {
          _sendNotFound(request, response);
        }
      });
    } else {
      _sendNotFound(request, response);
    }
  }

  void _handleEchoRequest(HttpRequest request, HttpResponse response) {
    response.headers.set("Access-Control-Allow-Origin", "*");
    request.pipe(response).catchError((e) {
      DebugLogger.warning(
          'HttpServer: error while closing the response stream', e);
    });
  }

  String _getFilePathFromRequestPath(String urlRequestPath) {
    // Go to the top of the file to see an explanation of the URL path scheme.
    var requestPath = urlRequestPath.substring(1);
    var pathSegments = requestPath.split('/');
    if (pathSegments.length > 0) {
      var basePath;
      var relativePath;
      if (pathSegments[0] == PREFIX_BUILDDIR) {
        basePath = _buildDirectory;
        relativePath = pathSegments.skip(1).join('/');
      } else if (pathSegments[0] == PREFIX_DARTDIR) {
        basePath = _codeRoot;
        relativePath = pathSegments.skip(1).join('/');
      }
      var packagesDirName = 'packages';
      var packagesIndex = pathSegments.indexOf(packagesDirName);
      if (packagesIndex != -1) {
        var start = packagesIndex + 1;
        basePath = path.join(_codeRoot, packagesDirName);
        relativePath = pathSegments.skip(start).join('/');
        DebugLogger.warning('the new relative path is $relativePath $basePath');
      }
      if (basePath != null && relativePath != null) {
        return path.join(basePath, relativePath);
      }
    }
    return null;
  }

  void _sendFileContent(HttpRequest request,
                        HttpResponse response,
                        int allowedPort,
                        String path,
                        File file) {
    if (allowedPort != -1) {
      var headerOrigin = request.headers.value('Origin');
      var allowedOrigin;
      if (headerOrigin != null) {
        var origin = Uri.parse(headerOrigin);
        // Allow loading from http://*:$allowedPort in browsers.
        allowedOrigin =
          '${origin.scheme}://${origin.host}:${allowedPort}';
      } else {
        // IE10 appears to be bugged and is not sending the Origin header
        // when making CORS requests to the same domain but different port.
        allowedOrigin = '*';
      }


      response.headers.set("Access-Control-Allow-Origin", allowedOrigin);
      response.headers.set('Access-Control-Allow-Credentials', 'true');
    } else {
      // No allowedPort specified. Allow from anywhere (but cross-origin
      // requests *with credentials* will fail because you can't use "*").
      response.headers.set("Access-Control-Allow-Origin", "*");
    }
    if (useContentSecurityPolicy) {
      // Chrome respects the standardized Content-Security-Policy header,
      // whereas Firefox and IE10 use X-Content-Security-Policy. Safari
      // still uses the WebKit- prefixed version.
      var content_header_value = "script-src 'self'; object-src 'self'";
      for (var header in ["Content-Security-Policy",
                          "X-Content-Security-Policy"]) {
        response.headers.set(header, content_header_value);
      }
      if (const ["safari"].contains(runtime)) {
        response.headers.set("X-WebKit-CSP", content_header_value);
      }
    }
    if (path.endsWith('.html')) {
      response.headers.set('Content-Type', 'text/html');
    } else if (path.endsWith('.js')) {
      response.headers.set('Content-Type', 'application/javascript');
    } else if (path.endsWith('.dart')) {
      response.headers.set('Content-Type', 'application/dart');
    }
    file.openRead().pipe(response).catchError((e) {
      DebugLogger.warning(
          'HttpServer: error while closing the response stream', e);
    });
  }

  void _sendNotFound(HttpRequest request, HttpResponse response) {
    DebugLogger.warning('HttpServer: could not find file for request path: '
                        '"${request.uri.path}"');
    response.statusCode = HttpStatus.NOT_FOUND;
    response.close();
    response.done.catchError((e) {
      DebugLogger.warning(
          'HttpServer: error while closing the response stream', e);
    });
  }
}

