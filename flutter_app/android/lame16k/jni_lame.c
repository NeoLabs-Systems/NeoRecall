#include <jni.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lame.h"

static lame_global_flags *g_lame = NULL;
static FILE *g_out = NULL;

static void close_encoder(void) {
  if (g_lame != NULL) {
    lame_close(g_lame);
    g_lame = NULL;
  }
  if (g_out != NULL) {
    fclose(g_out);
    g_out = NULL;
  }
}

static void init_encoder(
    JNIEnv *env,
    jint in_rate,
    jint out_rate,
    jint channels,
    jint bitrate,
    jint quality,
    jstring path,
    const char *mode
) {
  close_encoder();
  const char *filename = (*env)->GetStringUTFChars(env, path, NULL);
  if (filename == NULL) return;
  g_out = fopen(filename, mode);
  (*env)->ReleaseStringUTFChars(env, path, filename);
  if (g_out == NULL) return;

  g_lame = lame_init();
  if (g_lame == NULL) {
    fclose(g_out);
    g_out = NULL;
    return;
  }
  lame_set_in_samplerate(g_lame, in_rate > 0 ? in_rate : 16000);
  lame_set_out_samplerate(g_lame, out_rate > 0 ? out_rate : in_rate);
  lame_set_num_channels(g_lame, channels > 0 ? channels : 1);
  if (bitrate > 0) lame_set_brate(g_lame, bitrate);
  if (quality >= 0 && quality <= 9) lame_set_quality(g_lame, quality);
  lame_init_params(g_lame);
}

JNIEXPORT jstring JNICALL
Java_ai_plaud_android_plaud_lame_LameUtils_stringFromJNI(JNIEnv *env, jobject obj) {
  (void)obj;
  return (*env)->NewStringUTF(env, get_lame_version());
}

JNIEXPORT jstring JNICALL
Java_ai_plaud_android_plaud_lame_LameUtils_getVersion(JNIEnv *env, jobject obj) {
  (void)obj;
  return (*env)->NewStringUTF(env, get_lame_version());
}

JNIEXPORT void JNICALL
Java_ai_plaud_android_plaud_lame_LameUtils_initReWrite(
    JNIEnv *env,
    jobject obj,
    jint in_rate,
    jint out_rate,
    jint channels,
    jint bitrate,
    jint quality,
    jstring path
) {
  (void)obj;
  init_encoder(env, in_rate, out_rate, channels, bitrate, quality, path, "wb");
}

JNIEXPORT void JNICALL
Java_ai_plaud_android_plaud_lame_LameUtils_initAppend(
    JNIEnv *env,
    jobject obj,
    jint in_rate,
    jint out_rate,
    jint channels,
    jint bitrate,
    jint quality,
    jstring path
) {
  (void)obj;
  init_encoder(env, in_rate, out_rate, channels, bitrate, quality, path, "ab");
}

JNIEXPORT jint JNICALL
Java_ai_plaud_android_plaud_lame_LameUtils_encode(
    JNIEnv *env,
    jobject obj,
    jshortArray left,
    jshortArray right,
    jint samples
) {
  (void)obj;
  if (g_lame == NULL || g_out == NULL || samples <= 0) return -1;
  jshort *l = (*env)->GetShortArrayElements(env, left, NULL);
  jshort *r = right == NULL ? NULL : (*env)->GetShortArrayElements(env, right, NULL);
  if (l == NULL) return -1;
  const int max_out = samples * 2 + 7200;
  unsigned char *mp3 = malloc((size_t)max_out);
  int wrote = -1;
  if (mp3 != NULL) {
    wrote = lame_encode_buffer(
        g_lame,
        l,
        r == NULL ? l : r,
        samples,
        mp3,
        max_out
    );
    if (wrote > 0) fwrite(mp3, 1, (size_t)wrote, g_out);
    free(mp3);
  }
  (*env)->ReleaseShortArrayElements(env, left, l, JNI_ABORT);
  if (r != NULL) (*env)->ReleaseShortArrayElements(env, right, r, JNI_ABORT);
  return wrote;
}

JNIEXPORT jint JNICALL
Java_ai_plaud_android_plaud_lame_LameUtils_flush(JNIEnv *env, jobject obj) {
  (void)env;
  (void)obj;
  if (g_lame == NULL || g_out == NULL) return -1;
  unsigned char mp3[7200];
  const int wrote = lame_encode_flush(g_lame, mp3, (int)sizeof(mp3));
  if (wrote > 0) fwrite(mp3, 1, (size_t)wrote, g_out);
  return wrote;
}

JNIEXPORT void JNICALL
Java_ai_plaud_android_plaud_lame_LameUtils_writeTags(JNIEnv *env, jobject obj) {
  (void)env;
  (void)obj;
  if (g_lame == NULL || g_out == NULL) return;
  lame_mp3_tags_fid(g_lame, g_out);
}

JNIEXPORT void JNICALL
Java_ai_plaud_android_plaud_lame_LameUtils_close(JNIEnv *env, jobject obj) {
  (void)env;
  (void)obj;
  close_encoder();
}
