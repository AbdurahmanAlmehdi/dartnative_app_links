// app_links_kit Android bridge:
// Dart --[FFI]--> DNAppLinks* (C) --[JNI]--> com.dartnative.applinks.AppLinksKit
// and back through the dispatcher pointer Dart handed over.
//
// Strings cross JNI as UTF-8 byte arrays: GetStringUTFChars yields modified
// UTF-8, which corrupts non-BMP characters in IRIs.

#include <android/log.h>
#include <dlfcn.h>
#include <jni.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>

#define LOG_TAG "AppLinksKit"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

JavaVM* g_jvm = nullptr;
jclass g_kit = nullptr;
jmethodID g_setDispatcher = nullptr;
jmethodID g_initialLink = nullptr;
jmethodID g_latestLink = nullptr;
jmethodID g_startListening = nullptr;
jmethodID g_stopListening = nullptr;

JNIEnv* env() {
    if (!g_jvm) return nullptr;
    JNIEnv* e = nullptr;
    if (g_jvm->GetEnv(reinterpret_cast<void**>(&e), JNI_VERSION_1_6) == JNI_OK) return e;
    if (g_jvm->AttachCurrentThread(&e, nullptr) == JNI_OK) return e;
    return nullptr;
}

bool clearException(JNIEnv* e) {
    if (!e->ExceptionCheck()) return false;
    e->ExceptionDescribe();
    e->ExceptionClear();
    return true;
}

// malloc'd, NUL-terminated copy of a UTF-8 byte array; Dart frees it.
char* copyBytes(JNIEnv* e, jbyteArray bytes) {
    if (!bytes) return nullptr;
    const jsize len = e->GetArrayLength(bytes);
    char* out = static_cast<char*>(malloc(static_cast<size_t>(len) + 1));
    if (!out) return nullptr;
    e->GetByteArrayRegion(bytes, 0, len, reinterpret_cast<jbyte*>(out));
    out[len] = '\0';
    return out;
}

char* callBytes(jmethodID method) {
    JNIEnv* e = env();
    if (!e || !g_kit || !method) return nullptr;
    auto bytes = static_cast<jbyteArray>(e->CallStaticObjectMethod(g_kit, method));
    if (clearException(e)) return nullptr;
    char* out = copyBytes(e, bytes);
    if (bytes) e->DeleteLocalRef(bytes);
    return out;
}

void callVoid(jmethodID method) {
    JNIEnv* e = env();
    if (!e || !g_kit || !method) return;
    e->CallStaticVoidMethod(g_kit, method);
    clearException(e);
}

jmethodID staticMethod(JNIEnv* e, const char* name, const char* sig) {
    jmethodID id = e->GetStaticMethodID(g_kit, name, sig);
    if (clearException(e) || !id) LOGE("AppLinksKit.%s%s not found", name, sig);
    return id;
}

}  // namespace

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void*) {
    g_jvm = vm;
    JNIEnv* e = nullptr;
    if (vm->GetEnv(reinterpret_cast<void**>(&e), JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
    jclass cls = e->FindClass("com/dartnative/applinks/AppLinksKit");
    if (clearException(e) || !cls) {
        // Keep loading: the Dart calls then no-op instead of crashing.
        LOGE("class com.dartnative.applinks.AppLinksKit not found");
        return JNI_VERSION_1_6;
    }
    g_kit = static_cast<jclass>(e->NewGlobalRef(cls));
    e->DeleteLocalRef(cls);
    g_setDispatcher = staticMethod(e, "setDispatcher", "(J)V");
    g_initialLink = staticMethod(e, "initialLinkBytes", "()[B");
    g_latestLink = staticMethod(e, "latestLinkBytes", "()[B");
    g_startListening = staticMethod(e, "startListening", "()[B");
    g_stopListening = staticMethod(e, "stopListening", "()V");
    return JNI_VERSION_1_6;
}

extern "C" __attribute__((visibility("default"))) void DNAppLinksSetDispatcher(int64_t fnPtr) {
    JNIEnv* e = env();
    if (!e || !g_kit || !g_setDispatcher) return;
    e->CallStaticVoidMethod(g_kit, g_setDispatcher, static_cast<jlong>(fnPtr));
    clearException(e);
}

extern "C" __attribute__((visibility("default"))) char* DNAppLinksGetInitialLink() {
    return callBytes(g_initialLink);
}

extern "C" __attribute__((visibility("default"))) char* DNAppLinksGetLatestLink() {
    return callBytes(g_latestLink);
}

extern "C" __attribute__((visibility("default"))) char* DNAppLinksStartListening() {
    return callBytes(g_startListening);
}

extern "C" __attribute__((visibility("default"))) void DNAppLinksStopListening() {
    callVoid(g_stopListening);
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_dartnative_applinks_AppLinksKit_nativeIsolateGen(JNIEnv*, jclass) {
    using GenFn = uint64_t (*)();
    static GenFn fn = nullptr;
    if (!fn) fn = reinterpret_cast<GenFn>(dlsym(RTLD_DEFAULT, "DN_IsolateGen"));
    return fn ? static_cast<jlong>(fn()) : 0;
}

// Dart copies the payload during this synchronous call, so a scoped buffer
// is enough.
extern "C" JNIEXPORT void JNICALL Java_com_dartnative_applinks_AppLinksKit_nativeDeliver(
    JNIEnv* e, jclass, jlong ptr, jlong token, jint type, jbyteArray payload) {
    if (!ptr) return;
    char* text = copyBytes(e, payload);
    if (!text) return;
    using Dispatch = void (*)(int64_t, int32_t, const char*);
    reinterpret_cast<Dispatch>(ptr)(static_cast<int64_t>(token), static_cast<int32_t>(type), text);
    free(text);
}
