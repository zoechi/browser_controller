// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Dart script to launch performance tests without WebDriver/Selenium.
///
/// WARNING: Although this is laid out like a package, it is not really a
/// package since it relies on test.dart files!
library browser_perf_testing;

import 'package:path/path.dart' as path;
import 'package:args/args.dart' as args_parser;

import 'browser_controller.dart';
import 'src/http_server.dart';
import 'dart:io';

const String ADDRESS = '127.0.0.1';

/// A map that is passed to the testing framework to specify what ports the
/// browser controller runs on.
final Map SERVER_CONFIG = {
  'test_driver_port': 0,
  'test_driver_error_port': 0
};

void main (List<String> args) {
  var options = _parseArguments(args);

  var codeRoot = options['code_root'];
  // Start a server to serve the entire repo: the http server is available on
  // window.location.port.
  var servers = new TestingServers(
      path.join(codeRoot, 'build', 'web'),
      codeRoot,
      false, options['browser']);
  servers.startServers(ADDRESS).then((_) {
    _runPerfTests(options, servers);
  });
}

/// Helper function to parse the arguments for this file.
args_parser.ArgResults _parseArguments(List<String> args) {
  var parser =  new args_parser.ArgParser();
  parser.addOption('browser', defaultsTo: 'chrome', help: 'Name of the browser'
      ' to run this test with.');
  parser.addOption('test_path', help: 'Path to the performance test we '
      'wish to run. This is in a form that can be served up by '
      'http_server.dart, so it begins with /code_root or some other server '
      'understood prefix.');
  parser.addOption('code_root', help: 'Path to the code we want to serve. By '
      'default this is one directory above the packageRoot.', defaultsTo:
      path.dirname(Platform.packageRoot));
  parser.addOption('checked', defaultsTo: 'false',
      help: 'Run this test in checked mode.');
  parser.addOption('window', defaultsTo: 'false',
      help: 'Open test in a separate window, rather than an iframe.');
  parser.addOption('executable', help: 'Path to the browser executable (if '
      'nonstandard).', defaultsTo: '');
  parser.addFlag('help', abbr: 'h', negatable: false, callback: (help) {
    if (help) {
      print(parser.getUsage());
      exit(0);
    };
  });
  parser.addOption('timeout', defaultsTo: '300',
      help: 'Maximum amount of time to let a test run, in seconds.');
  return parser.parse(args);
}

void _runPerfTests(args_parser.ArgResults options, TestingServers servers) {
  var browserName = options['browser'];

  var testRunner = new BrowserTestRunner(SERVER_CONFIG, ADDRESS, browserName, 1,
      checkedMode: options['checked'],
      testingServer: new BrowserTestingServer(SERVER_CONFIG, ADDRESS,
          options['window']),
      separateWindow: options['window'],
      executable: options['executable']);

  var url = 'http://$ADDRESS:${servers.port}${options["test_path"]}';

  BrowserTest browserTest = new BrowserTest(url,
      (BrowserTestOutput output) {
        var lines = output.lastKnownMessage.split('\n');
        for (var line in lines) {
          print(line);
        }
        testRunner.terminate();
        servers.stopServers();
      }, int.parse(options['timeout']));

  _startRunner(testRunner, browserTest, 3);
}

_startRunner(BrowserTestRunner testRunner, BrowserTest browserTest,
    num numRetries) {
  testRunner.start().then((started) {
    if (started) {
      testRunner.queueTest(browserTest);
    } else {
      if (numRetries > 0) {
        _startRunner(testRunner, browserTest, numRetries - 1);
      } else {
        print("Issue starting browser test runner $started");
        exit(1);
      }
    }
  });
}
