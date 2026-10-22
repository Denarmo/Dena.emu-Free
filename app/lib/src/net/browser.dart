// SPDX-License-Identifier: GPL-3.0-or-later
// Opening a link or file in the system browser (desktop).
import 'dart:io';

/// Opens [url] in the system browser; false when nothing could open it.
typedef UrlOpener = Future<bool> Function(Uri url);

/// The system browser: `rundll32 url.dll` on Windows (no shell, so `&` in
/// the URL is safe), `xdg-open` on Linux (the portal inside the Flatpak).
Future<bool> openInBrowser(Uri url) async {
  try {
    final r = Platform.isWindows
        ? await Process.run('rundll32', [
            'url.dll,FileProtocolHandler',
            url.toString(),
          ])
        : await Process.run('xdg-open', [url.toString()]);
    return r.exitCode == 0;
  } on ProcessException {
    return false;
  }
}
