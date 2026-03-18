#ifndef KEYFINDER_WRAPPER_H
#define KEYFINDER_WRAPPER_H

#ifdef __cplusplus
extern "C" {
#endif

/// Result from key detection. key is 0-24 (see key_t enum in constants.h)
/// 0=A_MAJOR, 1=A_MINOR, 2=Bb_MAJOR, ... 24=SILENCE
int keyfinder_detect_key(const float* samples, int sampleCount, int sampleRate);

#ifdef __cplusplus
}
#endif

#endif
