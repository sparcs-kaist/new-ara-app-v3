import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:new_ara_app/bridge/bridge_controller.dart';
import 'package:new_ara_app/bridge/bridge_protocol.dart';
import 'package:new_ara_app/constants/url_info.dart';

/// Entry point for the WebView-shell build of Ara.
///
/// The native side is intentionally tiny: load a single InAppWebView pointing
/// at `$newAraDefaultUrl/web_view/Main`, register the `FlutterChannel`
/// handler, and forward lifecycle/back events through the bridge. Everything
/// else lives in the Next.js app.
void main() async {
  final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  const String environment =
      String.fromEnvironment('ENV', defaultValue: 'development');
  await dotenv.load(fileName: '.env.$environment');

  newAraDefaultUrl = dotenv.env['NEW_ARA_DEFAULT_URL']!;
  newAraAuthority = dotenv.env['NEW_ARA_AUTHORITY']!;
  sparcsSSODefaultUrl = dotenv.env['SPARCS_SSO_DEFAULT_URL']!;

  runApp(const AraWebShell());
}

class AraWebShell extends StatelessWidget {
  const AraWebShell({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Ara',
      // The shell renders no Flutter text — every visible glyph comes from
      // the WebView (which loads its own Pretendard via @font-face). Keeping
      // the typeface bundled here would just bloat the APK.
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.white,
      ),
      home: const _WebShell(),
    );
  }
}

class _WebShell extends StatefulWidget {
  const _WebShell();

  @override
  State<_WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<_WebShell> {
  InAppWebViewController? _controller;
  late final BridgeController _bridge;
  late final PullToRefreshController _pullToRefresh;
  bool _firstFrameDone = false;
  // Timestamp of the last back-press that found no WebView history.
  // Used so the second press within 2s actually exits — matching the
  // Flutter Ara `MainNavigationTabPage` "한번 더 누르면 종료" pattern.
  DateTime? _lastBackAt;
  // Last URL the WebView is showing. Tracked via onUpdateVisitedHistory
  // (and onLoadStop as a fallback) because `controller.getUrl()` lags
  // behind `pushState`/`replaceState` on Android — Next.js navigation
  // would land on /web_view/Main but getUrl() would still return
  // /web_view/Login, so the Main exit-toast branch never fired.
  String _currentUrl = '';

  @override
  void initState() {
    super.initState();
    _pullToRefresh = PullToRefreshController(
      // iOS-style spinner — a brand-red ring matching the rest of the UI.
      // The native side owns the *visual* of pull-to-refresh; the web
      // listens for `refresh:requested` and answers with `refreshDone`.
      settings: PullToRefreshSettings(
        color: const Color(0xFFED3A3A),
      ),
      onRefresh: () async {
        await _bridge.emit(BridgeEvent.refreshRequested);
      },
    );
    _bridge = BridgeController(
      getWebView: () => _controller,
      getPullToRefresh: () => _pullToRefresh,
    )..start();
  }

  @override
  void dispose() {
    _bridge.dispose();
    super.dispose();
  }

  Uri get _entryUri => Uri.parse('$newAraDefaultUrl/web_view/Main');

  InAppWebViewSettings get _settings => InAppWebViewSettings(
        // Cookies persist in the platform cookie store; nothing else to do.
        sharedCookiesEnabled: true,
        thirdPartyCookiesEnabled: true,
        javaScriptEnabled: true,
        javaScriptCanOpenWindowsAutomatically: false,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        useShouldOverrideUrlLoading: true,
        transparentBackground: false,
        // iOS: get rid of the "Done" accessory bar above the keyboard.
        disableInputAccessoryView: true,
        // Android keyboard handling: let the page's visualViewport drive layout.
        useHybridComposition: true,
        supportZoom: false,
        // Kill the Android system WebView's overlay scrollbars — CSS
        // `::-webkit-scrollbar { display: none }` on the page can't
        // touch them because they're painted natively by the platform.
        // Both flags must agree for the change to take effect (per the
        // flutter_inappwebview docs). The native PullToRefreshController
        // remains the only refresh affordance.
        verticalScrollBarEnabled: false,
        horizontalScrollBarEnabled: false,
        // No bounce/glow on overscroll either; the page is supposed to
        // feel native-app, not browser-with-rubber-banding.
        overScrollMode: OverScrollMode.NEVER,
        // We control the user-agent so the web can detect "in app".
        applicationNameForUserAgent: 'AraNative/1.0',
        // iOS edge-swipe back gesture — Flutter's CupertinoPageRoute had
        // it natively; without it the WebView feels "non-iOS".
        allowsBackForwardNavigationGestures: true,
      );

  Future<NavigationActionPolicy?> _onShouldOverride(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    final url = action.request.url;
    if (url == null) return NavigationActionPolicy.ALLOW;

    final scheme = url.scheme;
    final isHttp = scheme == 'http' || scheme == 'https';
    final isOurHost = url.host == _entryUri.host;

    // 1. Tel / mail / market: hand off to the OS.
    if (!isHttp) {
      await _openExternal(url);
      return NavigationActionPolicy.CANCEL;
    }

    // 2. Off-domain http(s) navigations open in the system browser. SSO is
    //    in-flow (sparcs.org) so we whitelist a couple of hosts.
    final whitelist = <String>{
      _entryUri.host,
      Uri.tryParse(sparcsSSODefaultUrl)?.host ?? '',
      'sso.sparcs.org',
      'sso.kaist.ac.kr',
    }..removeWhere((s) => s.isEmpty);
    if (!isOurHost && !whitelist.contains(url.host)) {
      // Only redirect main-frame navigations the user explicitly triggered.
      if (action.isForMainFrame == true && action.navigationType != NavigationType.OTHER) {
        await _openExternal(url);
        return NavigationActionPolicy.CANCEL;
      }
    }

    return NavigationActionPolicy.ALLOW;
  }

  Future<void> _openExternal(Uri uri) async {
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('openExternal failed: $e');
    }
  }

  void _onWebViewCreated(InAppWebViewController controller) {
    _controller = controller;
    controller.addJavaScriptHandler(
      handlerName: kJsHandlerName,
      callback: (args) async {
        await _bridge.handleMessage(args);
      },
    );
  }

  void _onLoadStop(InAppWebViewController controller, WebUri? url) async {
    if (url != null) {
      _currentUrl = url.toString();
      // Wipe the SSO redirect chain from WebView history the moment we
      // land on Main via a real navigation. Without this, fresh-login
      // arrives at Main with Login → sparcs SSO → callback → auth-handler
      // still sitting in back/forward — `canGoBack=true` then races with
      // Android 13+'s OnBackInvokedCallback so the activity finishes
      // before `PopScope` can render the double-press toast. Cookie
      // re-launch never built that chain, which is why only fresh login
      // showed the single-press exit. SPA navigation (pushState) doesn't
      // fire onLoadStop, so sub-page back navigation from Main is
      // unaffected.
      if (_currentUrl.contains('/web_view/Main')) {
        try {
          await controller.clearHistory();
        } catch (e) {
          debugPrint('clearHistory failed: $e');
        }
      }
    }
    if (!_firstFrameDone) {
      _firstFrameDone = true;
      FlutterNativeSplash.remove();
    }
  }

  /// Fires for *every* URL change including SPA `pushState` /
  /// `replaceState` — the only signal Android's WebView gives us that
  /// is in sync with Next.js navigation. `controller.getUrl()` alone
  /// is not enough on Android.
  void _onUpdateVisitedHistory(
    InAppWebViewController controller,
    WebUri? url,
    bool? isReload,
  ) {
    if (url != null) _currentUrl = url.toString();
  }

  /// Returns `true` when the host should actually exit.
  ///
  /// KakaoTalk / Instagram pattern: hardware back navigates the WebView
  /// history one step at a time *unless* the user is already on the
  /// Main route — in which case the first press shows a toast and the
  /// second press within 2 seconds exits. The URL check short-circuits
  /// the SSO redirect chain that otherwise sits in WebView history
  /// (sso_login → sparcs SSO → callback → auth-handler → Main) and
  /// would force the user to back-traverse it before being able to exit.
  Future<bool> _onWillPop() async {
    final wv = _controller;
    if (wv == null) return true;

    // Prefer the URL tracked via onUpdateVisitedHistory; fall back to a
    // live `getUrl()` if for some reason the callback hasn't landed yet.
    final live = (await wv.getUrl())?.toString() ?? '';
    final url = _currentUrl.isNotEmpty ? _currentUrl : live;
    final onMain = url.contains('/web_view/Main');
    final canGoBack = await wv.canGoBack();
    debugPrint('[back] url=$url onMain=$onMain canGoBack=$canGoBack');

    if (!onMain && canGoBack) {
      await wv.goBack();
      return false;
    }

    final now = DateTime.now();
    if (_lastBackAt != null &&
        now.difference(_lastBackAt!) < const Duration(seconds: 2)) {
      return true;
    }
    _lastBackAt = now;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..clearSnackBars()
      ..showSnackBar(
        const SnackBar(
          content: Text('한 번 더 누르면 종료됩니다.'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    return false;
  }

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark.copyWith(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ));

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldExit = await _onWillPop();
        if (shouldExit && mounted) {
          // Bottom of history AND this is the second press within 2s:
          // actually exit on Android. The toast was shown on press one.
          if (Platform.isAndroid) {
            await SystemNavigator.pop();
          }
        }
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        // We let the WebView fill the whole screen; the web layout reads
        // safe-area insets via the bridge handshake and applies them itself.
        body: InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri.uri(_entryUri)),
          initialSettings: _settings,
          pullToRefreshController: _pullToRefresh,
          onWebViewCreated: _onWebViewCreated,
          shouldOverrideUrlLoading: _onShouldOverride,
          onLoadStop: _onLoadStop,
          onUpdateVisitedHistory: _onUpdateVisitedHistory,
          onPermissionRequest: (controller, request) async {
            return PermissionResponse(
              resources: request.resources,
              action: PermissionResponseAction.GRANT,
            );
          },
          onConsoleMessage: (controller, msg) {
            debugPrint('[webview] ${msg.messageLevel}: ${msg.message}');
          },
        ),
      ),
    );
  }
}
