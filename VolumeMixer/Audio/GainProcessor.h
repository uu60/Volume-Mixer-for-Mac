#ifndef GainProcessor_h
#define GainProcessor_h

#include <CoreAudio/CoreAudio.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VMGainProcessor VMGainProcessor;

VMGainProcessor * _Nullable VMGainProcessorCreate(float initialGain);
void VMGainProcessorSetTarget(VMGainProcessor * _Nonnull processor, float gain);
void VMGainProcessorProcess(VMGainProcessor * _Nonnull processor,
                            const AudioBufferList * _Nonnull input,
                            AudioBufferList * _Nonnull output);
void VMGainProcessorDestroy(VMGainProcessor * _Nullable processor);

#ifdef __cplusplus
}
#endif

#endif
