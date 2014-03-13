// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/*
 * The communication protocol between test_controller.js and the driving
 * page are JSON encoded messages of the following form:
 *   message = {
 *      is_first_message: true/false,
 *      is_status_update: true/false,
 *      is_done: true/false,
 *      message: message_content,
 *   }
 *
 * The first message should have [is_first_message] set, the last message
 * should have [is_done] set. Status updates should have [is_status_update] set.
 *
 * The [message_content] can be be any content. In our case it will a list of
 * events encoded in JSON. See the next comment further down about what an event
 * is.
 */

// Returns the driving window object if available
function getDriverWindow() {
  if (window != window.parent) {
    // We're running in an iframe.
    return window.parent;
  } else if (window.opener) {
    // We were opened by another window.
    return window.opener;
  }
  return null;
}

var driver = getDriverWindow();

driver.postMessage(JSON.stringify({
  message: '',
  is_first_message: true,
  is_status_update: false,
  is_done: false
}), '*');

function reportPerformanceTestDone() {
  driver.postMessage(JSON.stringify({
    message: '' + window.document.documentElement.innerHTML,
    is_first_message: false,
    is_status_update: false,
    is_done: true
  }), '*');
}

