#include "GainProcessor.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct VMGainProcessor {
    _Atomic float target;
    float current;
};

VMGainProcessor *VMGainProcessorCreate(float initialGain) {
    VMGainProcessor *processor = calloc(1, sizeof(VMGainProcessor));
    if (processor == NULL) return NULL;
    atomic_init(&processor->target, initialGain);
    processor->current = initialGain;
    return processor;
}

void VMGainProcessorSetTarget(VMGainProcessor *processor, float gain) {
    if (processor == NULL) return;
    atomic_store_explicit(&processor->target, gain, memory_order_relaxed);
}

void VMGainProcessorProcess(VMGainProcessor *processor,
                            const AudioBufferList *input,
                            AudioBufferList *output) {
    if (processor == NULL || input == NULL || output == NULL) return;

    const float target = atomic_load_explicit(&processor->target, memory_order_relaxed);
    float current = processor->current;
    const float smoothing = 0.0025f; // About 8 ms to settle at 48 kHz.

    UInt32 framesProcessed = 0;
    for (UInt32 bufferIndex = 0; bufferIndex < output->mNumberBuffers; bufferIndex++) {
        AudioBuffer *outBuffer = &output->mBuffers[bufferIndex];
        if (outBuffer->mData == NULL) continue;

        if (input->mNumberBuffers == 0) {
            memset(outBuffer->mData, 0, outBuffer->mDataByteSize);
            continue;
        }

        const UInt32 inputIndex = bufferIndex < input->mNumberBuffers ? bufferIndex : 0;
        const AudioBuffer *inBuffer = &input->mBuffers[inputIndex];
        if (inBuffer->mData == NULL) {
            memset(outBuffer->mData, 0, outBuffer->mDataByteSize);
            continue;
        }

        const UInt32 byteCount = outBuffer->mDataByteSize < inBuffer->mDataByteSize
            ? outBuffer->mDataByteSize : inBuffer->mDataByteSize;
        const UInt32 sampleCount = byteCount / sizeof(float);
        const UInt32 channelCount = outBuffer->mNumberChannels > 0
            ? outBuffer->mNumberChannels : 1;
        const UInt32 frameCount = sampleCount / channelCount;
        const float *source = (const float *)inBuffer->mData;
        float *destination = (float *)outBuffer->mData;

        float bufferGain = current;
        for (UInt32 frame = 0; frame < frameCount; frame++) {
            bufferGain += (target - bufferGain) * smoothing;
            for (UInt32 channel = 0; channel < channelCount; channel++) {
                const UInt32 sample = frame * channelCount + channel;
                destination[sample] = source[sample] * bufferGain;
            }
        }
        if (frameCount > framesProcessed) framesProcessed = frameCount;

        if (outBuffer->mDataByteSize > byteCount) {
            memset((char *)outBuffer->mData + byteCount, 0,
                   outBuffer->mDataByteSize - byteCount);
        }
    }

    // Advance the shared envelope once per frame, not once per channel/buffer.
    for (UInt32 frame = 0; frame < framesProcessed; frame++) {
        current += (target - current) * smoothing;
    }
    processor->current = current;
}

void VMGainProcessorDestroy(VMGainProcessor *processor) {
    free(processor);
}
