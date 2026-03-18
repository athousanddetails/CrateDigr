#include "../include/keyfinder_wrapper.h"
#include "../include/keyfinder/keyfinder.h"
#include "../include/keyfinder/audiodata.h"

extern "C" {

int keyfinder_detect_key(const float* samples, int sampleCount, int sampleRate) {
    try {
        KeyFinder::AudioData audio;
        audio.setChannels(1);
        audio.setFrameRate(static_cast<unsigned int>(sampleRate));
        audio.addToFrameCount(static_cast<unsigned int>(sampleCount));

        for (int i = 0; i < sampleCount; i++) {
            audio.setSample(i, static_cast<double>(samples[i]));
        }

        KeyFinder::KeyFinder kf;
        KeyFinder::key_t result = kf.keyOfAudio(audio);
        return static_cast<int>(result);
    } catch (...) {
        return 24; // SILENCE on error
    }
}

}
