#include "hm_stretch.h"
#include "signalsmith-stretch.h"

struct hm_stretch {
    signalsmith::stretch::SignalsmithStretch<float> engine;
};

extern "C" {

hm_stretch *hm_stretch_create(float sample_rate) {
    auto *s = new hm_stretch();
    s->engine.presetDefault(1, sample_rate);
    return s;
}

void hm_stretch_destroy(hm_stretch *s) { delete s; }

void hm_stretch_set_transpose(hm_stretch *s, float factor) { s->engine.setTransposeFactor(factor); }

void hm_stretch_process(hm_stretch *s, const float *input, float *output, int frames) {
    const float *ins[1] = {input};
    float *outs[1] = {output};
    s->engine.process(ins, frames, outs, frames);
}

int hm_stretch_latency(const hm_stretch *s) { return s->engine.inputLatency() + s->engine.outputLatency(); }

int hm_stretch_input_latency(const hm_stretch *s) { return s->engine.inputLatency(); }

}
