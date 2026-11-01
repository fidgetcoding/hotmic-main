#ifndef HM_STRETCH_H
#define HM_STRETCH_H

#ifdef __cplusplus
extern "C" {
#endif

/// Mono pitch shifter (signalsmith-stretch). Not real-time safe to create; process is.
typedef struct hm_stretch hm_stretch;

hm_stretch *hm_stretch_create(float sample_rate);
void hm_stretch_destroy(hm_stretch *s);
/// Pitch multiplier, 1 = unchanged, 2 = up an octave. Duration is never changed.
void hm_stretch_set_transpose(hm_stretch *s, float factor);
void hm_stretch_process(hm_stretch *s, const float *input, float *output, int frames);
/// Output lags input by this many frames.
int hm_stretch_latency(const hm_stretch *s);
/// The frame being pitch-shifted right now is this far behind the newest input.
int hm_stretch_input_latency(const hm_stretch *s);

#ifdef __cplusplus
}
#endif
#endif
