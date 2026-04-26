# Keep the plugin class and @Command-annotated entry points; the Tauri host
# resolves them by name via reflection.
-keep class app.tauri.oauth_session.OAuthSessionPlugin { *; }
-keep class app.tauri.oauth_session.RedirectActivity { *; }
-keepclassmembers class app.tauri.oauth_session.** {
    @app.tauri.annotation.Command *;
}
