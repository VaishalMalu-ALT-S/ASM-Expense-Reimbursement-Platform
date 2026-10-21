# ==========================================
# Flutter Core & Plugins
# ==========================================
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.** { *; }

# ==========================================
# SharedPreferences & Pigeon
# ==========================================
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keep class io.flutter.plugins.sharedpreferences.SharedPreferencesApiRegistrar { *; }
-keep class io.flutter.plugins.sharedpreferences.SharedPreferencesAsyncApiRegistrar { *; }
-keep class io.flutter.plugins.sharedpreferences.SharedPreferencesPigeonOptions { *; }

# ==========================================
# Image Picker & File Picker
# ==========================================
-keep class io.flutter.plugins.imagepicker.** { *; }
-keep class com.mr.flutter.plugin.filepicker.** { *; }

# ==========================================
# AndroidX & Security
# ==========================================
-keep class androidx.core.** { *; }
-keep class androidx.versionedparcelable.** { *; }
-keep class androidx.security.crypto.** { *; }

# ==========================================
# Reflection & Type Signatures
# ==========================================
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod

# ==========================================
# Suppress Play Core warnings
# ==========================================
-dontwarn com.google.android.play.core.**
-dontwarn **

