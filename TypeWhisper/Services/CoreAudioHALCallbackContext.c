#include "CoreAudioHALCallbackContext.h"

#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

struct CoreAudioHALCallbackContext {
    _Atomic(unsigned long long) state;
    void *payload;
};

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2,
               "CoreAudio callback context requires a lock-free C11 atomic word");

#define CORE_AUDIO_HAL_CALLBACK_CLOSED ((unsigned long long)1)
#define CORE_AUDIO_HAL_CALLBACK_TEARDOWN_CLAIMED ((unsigned long long)2)
#define CORE_AUDIO_HAL_CALLBACK_DESTROY_SEALED ((unsigned long long)4)
#define CORE_AUDIO_HAL_CALLBACK_IN_FLIGHT_INCREMENT ((unsigned long long)8)
#define CORE_AUDIO_HAL_CALLBACK_IN_FLIGHT_MASK (~((unsigned long long)7))

CoreAudioHALCallbackContext *CoreAudioHALCallbackContextCreate(void *payload) {
    if (payload == NULL) {
        return NULL;
    }

    CoreAudioHALCallbackContext *context = calloc(1, sizeof(*context));
    if (context == NULL) {
        return NULL;
    }

    atomic_init(&context->state, CORE_AUDIO_HAL_CALLBACK_CLOSED);
    context->payload = payload;
    return context;
}

void CoreAudioHALCallbackContextDestroy(CoreAudioHALCallbackContext *context) {
    free(context);
}

bool CoreAudioHALCallbackContextOpen(CoreAudioHALCallbackContext *context) {
    unsigned long long observed = atomic_load_explicit(&context->state, memory_order_acquire);

    for (;;) {
        if ((observed & CORE_AUDIO_HAL_CALLBACK_TEARDOWN_CLAIMED) != 0) {
            return false;
        }
        if ((observed & CORE_AUDIO_HAL_CALLBACK_CLOSED) == 0) {
            return true;
        }
        // Defensively prevent future callers from reopening a reused context
        // while a callback is still observing its closed state.
        if ((observed & CORE_AUDIO_HAL_CALLBACK_IN_FLIGHT_MASK) != 0) {
            return false;
        }

        const unsigned long long desired = observed & ~CORE_AUDIO_HAL_CALLBACK_CLOSED;
        if (atomic_compare_exchange_weak_explicit(
                &context->state,
                &observed,
                desired,
                memory_order_release,
                memory_order_acquire)) {
            return true;
        }
    }
}

bool CoreAudioHALCallbackContextEnter(
    CoreAudioHALCallbackContext *context,
    void **payload
) {
    unsigned long long observed = atomic_load_explicit(&context->state, memory_order_acquire);

    for (;;) {
        if ((observed & CORE_AUDIO_HAL_CALLBACK_DESTROY_SEALED) != 0) {
            *payload = NULL;
            return false;
        }

        // Rejected callbacks count too: they still dereference this context while
        // observing the closed gate and must finish before it is destroyed.
        if ((observed & CORE_AUDIO_HAL_CALLBACK_IN_FLIGHT_MASK) == CORE_AUDIO_HAL_CALLBACK_IN_FLIGHT_MASK) {
            *payload = NULL;
            return false;
        }

        const unsigned long long desired = observed + CORE_AUDIO_HAL_CALLBACK_IN_FLIGHT_INCREMENT;
        if (atomic_compare_exchange_weak_explicit(
                &context->state,
                &observed,
                desired,
                memory_order_acq_rel,
                memory_order_acquire)) {
            *payload = (observed & CORE_AUDIO_HAL_CALLBACK_CLOSED) == 0 ? context->payload : NULL;
            return true;
        }
    }
}

void CoreAudioHALCallbackContextLeave(CoreAudioHALCallbackContext *context) {
    atomic_fetch_sub_explicit(
        &context->state,
        CORE_AUDIO_HAL_CALLBACK_IN_FLIGHT_INCREMENT,
        memory_order_release
    );
}

bool CoreAudioHALCallbackContextBeginTeardown(CoreAudioHALCallbackContext *context) {
    unsigned long long observed = atomic_load_explicit(&context->state, memory_order_acquire);

    for (;;) {
        if ((observed & CORE_AUDIO_HAL_CALLBACK_TEARDOWN_CLAIMED) != 0) {
            return false;
        }

        const unsigned long long desired = observed |
            CORE_AUDIO_HAL_CALLBACK_CLOSED |
            CORE_AUDIO_HAL_CALLBACK_TEARDOWN_CLAIMED;
        if (atomic_compare_exchange_weak_explicit(
                &context->state,
                &observed,
                desired,
                memory_order_acq_rel,
                memory_order_acquire)) {
            return true;
        }
    }
}

bool CoreAudioHALCallbackContextIsDrained(CoreAudioHALCallbackContext *context) {
    const unsigned long long state = atomic_load_explicit(&context->state, memory_order_acquire);
    return (state & CORE_AUDIO_HAL_CALLBACK_IN_FLIGHT_MASK) == 0;
}

bool CoreAudioHALCallbackContextSealForDestruction(CoreAudioHALCallbackContext *context) {
    unsigned long long observed = atomic_load_explicit(&context->state, memory_order_acquire);

    for (;;) {
        if ((observed & CORE_AUDIO_HAL_CALLBACK_TEARDOWN_CLAIMED) == 0) {
            return false;
        }
        if ((observed & CORE_AUDIO_HAL_CALLBACK_DESTROY_SEALED) != 0) {
            return true;
        }
        if ((observed & CORE_AUDIO_HAL_CALLBACK_IN_FLIGHT_MASK) != 0) {
            return false;
        }

        const unsigned long long desired = observed | CORE_AUDIO_HAL_CALLBACK_DESTROY_SEALED;
        if (atomic_compare_exchange_weak_explicit(
                &context->state,
                &observed,
                desired,
                memory_order_acq_rel,
                memory_order_acquire)) {
            return true;
        }
    }
}

// MARK: - Realtime input render state

#define CORE_AUDIO_HAL_INPUT_MAX_CHANNELS ((uint32_t)64)
#define CORE_AUDIO_HAL_INPUT_MAX_FRAMES_PER_SLICE ((uint32_t)1 << 20)
#define CORE_AUDIO_HAL_INPUT_MAX_RING_CAPACITY ((uint64_t)1 << 27)
#define CORE_AUDIO_HAL_INPUT_CACHE_LINE 64

_Static_assert(ATOMIC_INT_LOCK_FREE == 2,
               "CoreAudio input render state requires lock-free 32-bit atomics");

struct CoreAudioHALInputRenderState {
    // Written before the callback gate opens, read-only afterwards.
    uint32_t channelCount;
    uint32_t maximumFramesPerSlice;
    CoreAudioHALInputRenderProc renderProc;
    void *renderContext;
    AudioBufferList *bufferList;
    float *renderStorage;
    const float **renderChannels;
    float *ring;
    uint64_t ringCapacity;
    uint64_t ringMask;

    // Monotonic slot indices. The producer owns writeIndex, the consumer owns readIndex.
    _Alignas(CORE_AUDIO_HAL_INPUT_CACHE_LINE) _Atomic(uint64_t) writeIndex;
    _Alignas(CORE_AUDIO_HAL_INPUT_CACHE_LINE) _Atomic(uint64_t) readIndex;

    _Alignas(CORE_AUDIO_HAL_INPUT_CACHE_LINE) _Atomic(uint64_t) droppedFrames;
    _Atomic(uint64_t) renderFailures;
    _Atomic(int32_t) lastRenderFailureStatus;
};

CoreAudioHALInputRenderState *CoreAudioHALInputRenderStateCreate(
    uint32_t channelCount,
    CoreAudioHALInputRenderProc renderProc,
    void *renderContext
) {
    if (channelCount == 0 || channelCount > CORE_AUDIO_HAL_INPUT_MAX_CHANNELS ||
        renderProc == NULL || renderContext == NULL) {
        return NULL;
    }

    void *memory = NULL;
    if (posix_memalign(&memory, CORE_AUDIO_HAL_INPUT_CACHE_LINE, sizeof(CoreAudioHALInputRenderState)) != 0) {
        return NULL;
    }
    memset(memory, 0, sizeof(CoreAudioHALInputRenderState));

    CoreAudioHALInputRenderState *state = memory;
    state->channelCount = channelCount;
    state->renderProc = renderProc;
    state->renderContext = renderContext;
    atomic_init(&state->writeIndex, 0);
    atomic_init(&state->readIndex, 0);
    atomic_init(&state->droppedFrames, 0);
    atomic_init(&state->renderFailures, 0);
    atomic_init(&state->lastRenderFailureStatus, noErr);
    return state;
}

void CoreAudioHALInputRenderStateDestroy(CoreAudioHALInputRenderState *state) {
    free(state->bufferList);
    free(state->renderStorage);
    free((void *)state->renderChannels);
    free(state->ring);
    free(state);
}

bool CoreAudioHALInputRenderStatePrepare(
    CoreAudioHALInputRenderState *state,
    uint32_t maximumFramesPerSlice,
    uint64_t minimumRingCapacitySamples
) {
    if (state->bufferList != NULL ||
        maximumFramesPerSlice == 0 ||
        maximumFramesPerSlice > CORE_AUDIO_HAL_INPUT_MAX_FRAMES_PER_SLICE) {
        return false;
    }

    const uint64_t channelCount = state->channelCount;
    // Each slice is stored as one header slot followed by planar channel samples.
    const uint64_t largestPacket = 1 + (uint64_t)maximumFramesPerSlice * channelCount;
    uint64_t requiredCapacity = minimumRingCapacitySamples;
    if (requiredCapacity < largestPacket * 4) {
        requiredCapacity = largestPacket * 4;
    }
    uint64_t ringCapacity = 1;
    while (ringCapacity < requiredCapacity) {
        ringCapacity <<= 1;
        if (ringCapacity > CORE_AUDIO_HAL_INPUT_MAX_RING_CAPACITY) {
            return false;
        }
    }

    const size_t bufferListSize = offsetof(AudioBufferList, mBuffers) + (size_t)channelCount * sizeof(AudioBuffer);
    AudioBufferList *bufferList = calloc(1, bufferListSize);
    float *renderStorage = calloc((size_t)maximumFramesPerSlice * (size_t)channelCount, sizeof(float));
    const float **renderChannels = calloc((size_t)channelCount, sizeof(const float *));
    float *ring = calloc((size_t)ringCapacity, sizeof(float));
    if (bufferList == NULL || renderStorage == NULL || renderChannels == NULL || ring == NULL) {
        free(bufferList);
        free(renderStorage);
        free((void *)renderChannels);
        free(ring);
        return false;
    }

    bufferList->mNumberBuffers = state->channelCount;
    for (uint32_t channel = 0; channel < state->channelCount; channel++) {
        bufferList->mBuffers[channel].mNumberChannels = 1;
        bufferList->mBuffers[channel].mDataByteSize = 0;
        bufferList->mBuffers[channel].mData = renderStorage + (size_t)channel * maximumFramesPerSlice;
    }

    state->maximumFramesPerSlice = maximumFramesPerSlice;
    state->renderStorage = renderStorage;
    state->renderChannels = renderChannels;
    state->ring = ring;
    state->ringCapacity = ringCapacity;
    state->ringMask = ringCapacity - 1;
    state->bufferList = bufferList;
    return true;
}

uint64_t CoreAudioHALInputRenderStateRingCapacity(CoreAudioHALInputRenderState *state) {
    return state->ringCapacity;
}

static void CoreAudioHALInputRenderStateRecordFailure(
    CoreAudioHALInputRenderState *state,
    OSStatus status
) {
    atomic_fetch_add_explicit(&state->renderFailures, 1, memory_order_relaxed);
    atomic_store_explicit(&state->lastRenderFailureStatus, status, memory_order_relaxed);
}

static void CoreAudioHALInputRingCopyIn(
    CoreAudioHALInputRenderState *state,
    uint64_t position,
    const float *source,
    uint32_t count
) {
    const uint64_t offset = position & state->ringMask;
    const uint64_t firstCount = count < state->ringCapacity - offset ? count : state->ringCapacity - offset;
    memcpy(state->ring + offset, source, (size_t)firstCount * sizeof(float));
    if (firstCount < count) {
        memcpy(state->ring, source + firstCount, (size_t)(count - firstCount) * sizeof(float));
    }
}

static void CoreAudioHALInputRingCopyOut(
    CoreAudioHALInputRenderState *state,
    uint64_t position,
    float *destination,
    uint32_t count
) {
    const uint64_t offset = position & state->ringMask;
    const uint64_t firstCount = count < state->ringCapacity - offset ? count : state->ringCapacity - offset;
    memcpy(destination, state->ring + offset, (size_t)firstCount * sizeof(float));
    if (firstCount < count) {
        memcpy(destination + firstCount, state->ring, (size_t)(count - firstCount) * sizeof(float));
    }
}

bool CoreAudioHALInputRenderStateWriteSlice(
    CoreAudioHALInputRenderState *state,
    const float *const *channels,
    uint32_t frameCount
) {
    if (state->ring == NULL || frameCount == 0) {
        return false;
    }
    if (frameCount > state->maximumFramesPerSlice) {
        atomic_fetch_add_explicit(&state->droppedFrames, frameCount, memory_order_relaxed);
        return false;
    }

    const uint64_t packetSize = 1 + (uint64_t)frameCount * state->channelCount;
    const uint64_t writeIndex = atomic_load_explicit(&state->writeIndex, memory_order_relaxed);
    const uint64_t readIndex = atomic_load_explicit(&state->readIndex, memory_order_acquire);
    if (packetSize > state->ringCapacity - (writeIndex - readIndex)) {
        atomic_fetch_add_explicit(&state->droppedFrames, frameCount, memory_order_relaxed);
        return false;
    }

    const uint32_t header = frameCount;
    memcpy(state->ring + (writeIndex & state->ringMask), &header, sizeof(header));
    uint64_t position = writeIndex + 1;
    for (uint32_t channel = 0; channel < state->channelCount; channel++) {
        CoreAudioHALInputRingCopyIn(state, position, channels[channel], frameCount);
        position += frameCount;
    }

    atomic_store_explicit(&state->writeIndex, position, memory_order_release);
    return true;
}

uint32_t CoreAudioHALInputRenderStatePeekSliceFrameCount(CoreAudioHALInputRenderState *state) {
    if (state->ring == NULL) {
        return 0;
    }
    const uint64_t readIndex = atomic_load_explicit(&state->readIndex, memory_order_relaxed);
    const uint64_t writeIndex = atomic_load_explicit(&state->writeIndex, memory_order_acquire);
    if (readIndex == writeIndex) {
        return 0;
    }
    uint32_t frameCount = 0;
    memcpy(&frameCount, state->ring + (readIndex & state->ringMask), sizeof(frameCount));
    return frameCount;
}

uint32_t CoreAudioHALInputRenderStateSkipSlice(CoreAudioHALInputRenderState *state) {
    if (state->ring == NULL) {
        return 0;
    }
    const uint64_t readIndex = atomic_load_explicit(&state->readIndex, memory_order_relaxed);
    const uint64_t writeIndex = atomic_load_explicit(&state->writeIndex, memory_order_acquire);
    if (readIndex == writeIndex) {
        return 0;
    }
    uint32_t frameCount = 0;
    memcpy(&frameCount, state->ring + (readIndex & state->ringMask), sizeof(frameCount));
    atomic_fetch_add_explicit(&state->droppedFrames, frameCount, memory_order_relaxed);
    atomic_store_explicit(
        &state->readIndex,
        readIndex + 1 + (uint64_t)frameCount * state->channelCount,
        memory_order_release
    );
    return frameCount;
}

uint32_t CoreAudioHALInputRenderStateReadSlice(
    CoreAudioHALInputRenderState *state,
    float *const *channels,
    uint32_t frameCapacity
) {
    if (state->ring == NULL) {
        return 0;
    }

    for (;;) {
        const uint64_t readIndex = atomic_load_explicit(&state->readIndex, memory_order_relaxed);
        const uint64_t writeIndex = atomic_load_explicit(&state->writeIndex, memory_order_acquire);
        if (readIndex == writeIndex) {
            return 0;
        }

        uint32_t frameCount = 0;
        memcpy(&frameCount, state->ring + (readIndex & state->ringMask), sizeof(frameCount));
        uint64_t position = readIndex + 1;
        const uint64_t nextReadIndex = position + (uint64_t)frameCount * state->channelCount;

        if (frameCount <= frameCapacity) {
            for (uint32_t channel = 0; channel < state->channelCount; channel++) {
                CoreAudioHALInputRingCopyOut(state, position, channels[channel], frameCount);
                position += frameCount;
            }
            atomic_store_explicit(&state->readIndex, nextReadIndex, memory_order_release);
            return frameCount;
        }

        // The producer never writes slices larger than maximumFramesPerSlice, so this only
        // guards against a consumer passing an undersized destination.
        atomic_fetch_add_explicit(&state->droppedFrames, frameCount, memory_order_relaxed);
        atomic_store_explicit(&state->readIndex, nextReadIndex, memory_order_release);
    }
}

uint64_t CoreAudioHALInputRenderStateTakeDroppedFrames(CoreAudioHALInputRenderState *state) {
    return atomic_exchange_explicit(&state->droppedFrames, 0, memory_order_relaxed);
}

uint64_t CoreAudioHALInputRenderStateTakeRenderFailures(
    CoreAudioHALInputRenderState *state,
    OSStatus *lastStatus
) {
    const uint64_t failures = atomic_exchange_explicit(&state->renderFailures, 0, memory_order_relaxed);
    *lastStatus = atomic_load_explicit(&state->lastRenderFailureStatus, memory_order_relaxed);
    return failures;
}

OSStatus CoreAudioHALInputAudioUnitRender(
    void *context,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData
) {
    return AudioUnitRender((AudioUnit)context, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
}

static OSStatus CoreAudioHALInputRenderStateRender(
    CoreAudioHALInputRenderState *state,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inNumberFrames
) {
    AudioBufferList *bufferList = state->bufferList;
    if (bufferList == NULL || inNumberFrames == 0) {
        return noErr;
    }
    if (inNumberFrames > state->maximumFramesPerSlice) {
        atomic_fetch_add_explicit(&state->droppedFrames, inNumberFrames, memory_order_relaxed);
        CoreAudioHALInputRenderStateRecordFailure(state, kAudioUnitErr_TooManyFramesToProcess);
        return kAudioUnitErr_TooManyFramesToProcess;
    }

    const UInt32 byteSize = inNumberFrames * (UInt32)sizeof(float);
    bufferList->mNumberBuffers = state->channelCount;
    for (uint32_t channel = 0; channel < state->channelCount; channel++) {
        bufferList->mBuffers[channel].mNumberChannels = 1;
        bufferList->mBuffers[channel].mDataByteSize = byteSize;
        bufferList->mBuffers[channel].mData = state->renderStorage + (size_t)channel * state->maximumFramesPerSlice;
    }

    const OSStatus status = state->renderProc(
        state->renderContext,
        ioActionFlags,
        inTimeStamp,
        1,
        inNumberFrames,
        bufferList
    );
    if (status != noErr) {
        CoreAudioHALInputRenderStateRecordFailure(state, status);
        return status;
    }

    // Read back the buffer pointers in case the unit substituted its own storage.
    for (uint32_t channel = 0; channel < state->channelCount; channel++) {
        const float *data = bufferList->mBuffers[channel].mData;
        if (data == NULL) {
            atomic_fetch_add_explicit(&state->droppedFrames, inNumberFrames, memory_order_relaxed);
            CoreAudioHALInputRenderStateRecordFailure(state, kAudio_ParamError);
            return kAudio_ParamError;
        }
        state->renderChannels[channel] = data;
    }

    (void)CoreAudioHALInputRenderStateWriteSlice(state, state->renderChannels, inNumberFrames);
    return noErr;
}

OSStatus CoreAudioHALInputRenderCallback(
    void *inRefCon,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData
) {
    (void)inBusNumber;
    (void)ioData;

    CoreAudioHALCallbackContext *context = inRefCon;
    void *payload = NULL;
    if (!CoreAudioHALCallbackContextEnter(context, &payload)) {
        return noErr;
    }

    OSStatus status = noErr;
    if (payload != NULL) {
        status = CoreAudioHALInputRenderStateRender(payload, ioActionFlags, inTimeStamp, inNumberFrames);
    }
    CoreAudioHALCallbackContextLeave(context);
    return status;
}
