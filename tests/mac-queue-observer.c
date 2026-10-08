/* Test-only interposition: record PCM submitted to the real Core Audio queue.
   The player and its callbacks still run normally. This observes submitted
   PCM, not physical-device latency or the sound after Core Audio mixing. */
#include <AudioToolbox/AudioToolbox.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static unsigned char *pcm;
static size_t used,capacity;
static int failed;
void probe_reset(void) {pthread_mutex_lock(&lock);used=0;failed=0;pthread_mutex_unlock(&lock);}
size_t probe_bytes(void) {pthread_mutex_lock(&lock);size_t n=used;pthread_mutex_unlock(&lock);return n;}
int probe_equal(const void *reference,size_t bytes,int prefix) {
    pthread_mutex_lock(&lock);
    int ok=!failed && used<=bytes && (prefix || used==bytes) && !memcmp(pcm,reference,used);
    if(!ok) {
        size_t i=0,limit=used<bytes?used:bytes;
        while(i<limit && pcm[i]==((const unsigned char *)reference)[i])i++;
        fprintf(stderr,"capture mismatch: bytes=%zu reference=%zu first=%zu failed=%d\n",used,bytes,i,failed);
    }
    pthread_mutex_unlock(&lock);return ok;
}
static OSStatus observe(AudioQueueRef q,AudioQueueBufferRef b,UInt32 n,const AudioStreamPacketDescription *d) {
    pthread_mutex_lock(&lock);
    size_t end=used+b->mAudioDataByteSize;
    if(end>16*1024*1024)failed=1;
    else {
        if(end>capacity) {
            size_t cap=capacity?capacity:65536;while(cap<end)cap*=2;
            void *next=realloc(pcm,cap);
            if(!next)failed=1;else {pcm=next;capacity=cap;}
        }
        if(!failed) {memcpy(pcm+used,b->mAudioData,b->mAudioDataByteSize);used=end;}
    }
    pthread_mutex_unlock(&lock);
    return AudioQueueEnqueueBuffer(q,b,n,d);
}
static OSStatus observe_reset(AudioQueueRef q) {
    OSStatus result=AudioQueueReset(q);
    // The backend has suspended and joined in-flight refills before Reset.
    // Start seek capture here, excluding old callbacks racing the UI request.
    if(!result)probe_reset();
    return result;
}
__attribute__((used,section("__DATA,__interpose")))
static const struct {const void *replacement,*original;} interpose[]={
    {(const void *)observe,(const void *)AudioQueueEnqueueBuffer},
    {(const void *)observe_reset,(const void *)AudioQueueReset}
};
