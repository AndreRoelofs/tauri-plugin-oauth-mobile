# Keep the plugin class and @Command-annotated entry points; the Tauri host
# resolves them by name via reflection.
-keep class app.tauri.appauth.OAuthSessionPlugin { *; }
-keep class app.tauri.appauth.RedirectActivity { *; }
-keepclassmembers class app.tauri.appauth.** {
    @app.tauri.annotation.Command *;
}
